"""Download exactly the selected audio model and all of its offline dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

RESERVE = 25 * 1024**3

def main():
    p = argparse.ArgumentParser(); p.add_argument("--root", type=Path, required=True); p.add_argument("--model", required=True); args = p.parse_args()
    root = args.root.resolve(); model = args.model
    manifests = json.loads(Path(__file__).with_name("models.json").read_text())
    if model not in ["whisper-large-v3-turbo", "chatterbox-multilingual-v3", "nemotron-voicechat-11b-4bit"]: raise ValueError("Unsupported audio model")
    os.environ["HF_HOME"] = str(root / "huggingface")
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    from huggingface_hub import HfApi, snapshot_download, hf_hub_download
    api = HfApi()
    dependencies = [model] + (["tokenizer", "default-voice"] if model == "chatterbox-multilingual-v3" else (["whisper-processor"] if model == "whisper-large-v3-turbo" else []))
    patterns = {}
    expected = 0
    for name in dependencies:
        spec = manifests[name]
        info = api.model_info(spec["repo"], revision=spec["revision"], files_metadata=True)
        files = [f for f in info.siblings if (f.rfilename == "conds.safetensors" if name == "default-voice" else f.rfilename.endswith((".safetensors", ".json", ".tiktoken", ".model", ".txt")))]
        if name == "whisper-processor": files = [f for f in files if f.rfilename.endswith((".json", ".txt")) and f.rfilename not in ["config.json", "generation_config.json"]]
        patterns[name] = [f.rfilename for f in files]; expected += sum(f.size or 0 for f in files)
    if shutil.disk_usage(root).free < RESERVE + expected: raise RuntimeError("Model download would cross the 25 GiB free-space reserve")
    installed = {}
    for name in dependencies:
        spec = manifests[name]
        path = Path(snapshot_download(spec["repo"], revision=spec["revision"], allow_patterns=patterns[name], max_workers=2))
        # MLX's Chatterbox loader asks for the tokenizer's main ref. Bind it to our pinned revision in this private cache.
        refs = path.parent.parent / "refs"; refs.mkdir(exist_ok=True); (refs / "main").write_text(spec["revision"])
        installed[name] = str(path)
        if shutil.disk_usage(root).free < RESERVE: raise RuntimeError("Download stopped at the disk-space reserve")
    # Materialize a model view without duplicating weight blobs; include the upstream packaged default voice.
    local = root / "Installed" / model; local.mkdir(parents=True, exist_ok=True)
    for name in patterns[model]:
        target = local / name; target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists(): target.symlink_to(Path(installed[model]) / name)
    if model == "whisper-large-v3-turbo":
        for name in patterns["whisper-processor"]:
            target = local / name
            if not target.exists(): target.symlink_to(Path(installed["whisper-processor"]) / name)
    if model == "chatterbox-multilingual-v3":
        target = local / "conds.safetensors"
        if not target.exists(): target.symlink_to(Path(installed["default-voice"]) / "conds.safetensors")
    receipt = {"model": model, "revision": manifests[model]["revision"], "path":str(local), "dependencies":installed}
    files = []
    for name, folder in installed.items():
        for rel in patterns[name]:
            file = Path(folder) / rel
            h = hashlib.sha256()
            with file.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024*1024), b""): h.update(chunk)
            files.append({"path":str(file),"size":file.stat().st_size,"sha256":h.hexdigest()})
    receipt["files"] = files
    receipts = root / "models"; receipts.mkdir(exist_ok=True); destination = receipts / (model + ".json")
    temp = destination.with_suffix(".tmp"); temp.write_text(json.dumps(receipt)); os.chmod(temp,0o600); temp.replace(destination)
    print(json.dumps({"status":"success","model":model}),flush=True)

if __name__ == "__main__": main()
