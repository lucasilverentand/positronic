#!/usr/bin/env python3
"""Validate worker RPC and offline behavior with a tiny fake neural backend.

Uses the prepared audio Python for numpy/soundfile. Never loads model weights.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WORKER = Path(__file__).resolve().parents[1] / "Resources/Audio/worker.py"
PYTHON = os.environ.get("POSITRONIC_AUDIO_PYTHON", str(Path.home() / "Library/Application Support/MacModelAPI/Audio/venv/bin/python"))
MODEL = "nemotron-voicechat-11b-4bit"

class RealtimeWorkerTests(unittest.TestCase):
    def run_worker(self, requests):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); mocks = root / "mocks"; (mocks / "mlx").mkdir(parents=True)
            (mocks / "mlx/__init__.py").write_text("")
            (mocks / "mlx/core.py").write_text("def clear_cache(): pass\ndef reset_peak_memory(): pass\ndef get_peak_memory(): return 64\ndef get_active_memory(): return 64\n")
            (mocks / "mlx_vlm.py").write_text('''
import socket
import numpy as np
from types import SimpleNamespace
class Session:
    input_sample_rate = 16000
    output_sample_rate = 22050
    frame_samples = 1280
    def push_audio(self, samples, sample_rate):
        assert sample_rate == 16000 and samples.shape == (1280,)
        assert np.isfinite(samples).all()
        return [SimpleNamespace(kind="assistant_text_delta", delta="Hello"),
                SimpleNamespace(kind="user_transcript_delta", delta="Hi"),
                SimpleNamespace(kind="audio", samples=np.zeros(1764,dtype=np.float32))]
class Parent:
    def create_streaming_session(self, system_prompt, max_streaming_seconds):
        assert len(system_prompt.encode()) <= 1024 and 10 <= max_streaming_seconds <= 600
        return Session()
class Model:
    def create_session(self, processor): return Parent()
def load(path, trust_remote_code):
    assert trust_remote_code is False
    # The production worker must disable networking even during model load.
    try: socket.create_connection(("127.0.0.1",1))
    except RuntimeError: pass
    else: raise AssertionError("Worker allowed a network connection")
    return Model(), object()
''')
            (root / "Audio/models").mkdir(parents=True)
            (root / f"Audio/models/{MODEL}.json").write_text(json.dumps({"path":str(root),"files":[]}))
            env = dict(os.environ, PYTHONPATH=str(mocks), PYTHONDONTWRITEBYTECODE="1")
            result = subprocess.run([PYTHON,"-u",str(WORKER),str(root / "Audio")],input="\n".join(json.dumps(r) for r in requests)+"\n",text=True,capture_output=True,timeout=15,env=env)
            self.assertEqual(result.returncode,0)
            self.assertEqual(result.stderr,"")
            return [json.loads(line) for line in result.stdout.splitlines()]
    def test_native_duplex_rpc_pcm_and_offline_load(self):
        import base64
        result = self.run_worker([
            {"operation":"realtime_start","model":MODEL,"instructions":"Be brief.","seconds":300},
            {"operation":"realtime_step","model":MODEL,"audio":base64.b64encode(bytes(2560)).decode()},
            {"operation":"shutdown"}])
        self.assertTrue(result[-1]["ok"])
        events = result[-1]["events"]
        self.assertEqual([e["type"] for e in events],["response.text.delta","input_audio.transcript.delta","output_audio.delta"])
        self.assertEqual(len(base64.b64decode(events[-1]["audio"])),3528)
        self.assertEqual(events[-1]["sampleRate"],22050)
        self.assertNotIn("text",events[0]) # No cumulative transcript retained in RPC.
    def test_malformed_frames_and_unbounded_context_fail_without_leaking_input(self):
        for bad in [
            {"operation":"realtime_start","instructions":"PRIVATE"*200,"seconds":300},
            {"operation":"realtime_start","instructions":"PRIVATE","seconds":601},
            {"operation":"realtime_step","audio":"PRIVATE"},
        ]:
            result = self.run_worker([{**bad,"model":MODEL},{"operation":"shutdown"}])
            self.assertFalse(result[-1]["ok"])
            self.assertNotIn("PRIVATE",json.dumps(result))

if __name__ == "__main__": unittest.main()
