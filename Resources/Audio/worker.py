"""Private, offline-only JSON-lines worker. No user audio or text is logged."""
import contextlib
import gc
import json
import os
from pathlib import Path
import socket
import sys

root = Path(sys.argv[1]).resolve()
os.environ.update(HF_HOME=str(root / "huggingface"), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")
def no_network(*args, **kwargs): raise RuntimeError("Audio inference is offline; prepare all assets explicitly first")
socket.create_connection = no_network
socket.socket.connect = no_network
protocol = sys.stdout
# Third-party diagnostics must never contaminate RPC or retain prompts in logs.
sys.stdout = open(os.devnull, "w")
sys.stderr = open(os.devnull, "w")

def emit(value): protocol.write(json.dumps(value, ensure_ascii=False) + "\n"); protocol.flush()

import mlx.core as mx
import numpy as np
import soundfile as sf
loaded = None
loaded_id = None

def safe_job_file(value):
    file = Path(value).resolve()
    file.relative_to(root.parent / "Jobs")
    return file

def load(model):
    global loaded, loaded_id
    if loaded_id == model: return
    loaded = None; loaded_id = None; gc.collect(); mx.clear_cache()
    receipt = json.loads((root / "models" / (model + ".json")).read_text())
    for entry in receipt["files"]:
        if Path(entry["path"]).stat().st_size != entry["size"]: raise RuntimeError("An installed model asset is missing or damaged")
    emit({"event":"loading"})
    if model == "whisper-large-v3-turbo":
        from mlx_audio.stt.utils import load_model
    elif model == "chatterbox-multilingual-v3":
        from mlx_audio.tts.utils import load_model
    else: raise ValueError("Unsupported audio model")
    loaded = load_model(receipt["path"]); loaded_id = model
    emit({"event":"loaded", "model":model,"memory":mx.get_active_memory()})

for line in sys.stdin:
    request = None
    try:
        if len(line.encode()) > 64_000: raise ValueError("Worker request too large")
        request = json.loads(line); operation = request["operation"]
        if operation == "shutdown": break
        if operation == "unload":
            loaded = None; loaded_id = None; gc.collect(); mx.clear_cache(); emit({"ok":True}); continue
        model = request["model"]
        if model not in ["whisper-large-v3-turbo", "chatterbox-multilingual-v3"]: raise ValueError("Unsupported model")
        load(model); mx.reset_peak_memory()
        if operation == "load": emit({"ok":True,"memory":mx.get_active_memory()}); continue
        language = request.get("language", "en")
        if language not in ["en", "nl"]: raise ValueError("Unsupported language")
        output = safe_job_file(request["output"])
        emit({"event":"running"})
        if operation == "transcription" and model == "whisper-large-v3-turbo":
            source = safe_job_file(request["input"])
            info = sf.info(source)
            if info.duration > 1800 or info.samplerate != 16000 or info.channels != 1: raise ValueError("Expected normalized mono audio up to 30 minutes")
            audio, rate = sf.read(source, dtype="float32")
            result = loaded.generate(mx.array(audio), language=language, verbose=False, return_timestamps=True, word_timestamps=False, temperature=0.0)
            segments = []
            for segment in result.segments or []:
                start, end = segment.get("start"), segment.get("end")
                if start is None or end is None: raise RuntimeError("Transcription timestamps are missing")
                segments.append({"start":float(start),"end":float(end),"text":segment["text"]})
            output.write_text(json.dumps({"model":model,"language":language,"text":result.text,"segments":segments},ensure_ascii=False))
        elif operation == "speech" and model == "chatterbox-multilingual-v3":
            text = request["text"]
            if not text.strip() or len(text) > 5000: raise ValueError("Speech text must contain 1–5000 characters")
            # Use the upstream packaged default conditioning only; callers cannot supply a reference voice.
            import re
            sentences = [s.strip() for s in re.split(r'(?<=[.!?])\s+|\n+', text) if s.strip()]
            pieces = [s[i:i+350] for s in sentences for i in range(0,len(s),350)]
            frames = 0
            with sf.SoundFile(output, mode="w", samplerate=24000, channels=1, subtype="PCM_16",format="WAV") as writer:
                for index, piece in enumerate(pieces):
                    for result in loaded.generate(text=piece, lang_code=language, verbose=False, max_new_tokens=1500):
                        audio = np.asarray(result.audio).reshape(-1)
                        if not np.isfinite(audio).all(): raise RuntimeError("Model generated invalid audio")
                        frames += len(audio)
                        if frames > 24000*1800 or frames*2 > 64*1024**2: raise RuntimeError("Generated audio exceeds the output limit")
                        writer.write(audio)
                    emit({"event":"progress", "progress":(index+1)/len(pieces),"memory":mx.get_peak_memory()})
            if frames == 0: raise RuntimeError("The model generated no speech")
        else: raise ValueError("Unsupported operation/model combination")
        os.chmod(output,0o600)
        emit({"ok":True,"output":str(output),"memory":mx.get_peak_memory()})
    except Exception as error:
        if request and "output" in request:
            with contextlib.suppress(Exception): safe_job_file(request["output"]).unlink(missing_ok=True)
        # Do not echo model/library exceptions, which can include private input text.
        emit({"ok":False,"error":"Local audio failed. Verify the installed assets, language, file format and resource availability."})
