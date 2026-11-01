#!/usr/bin/env python3
"""Explicit managed-runtime preparation; never called by inference or startup."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

UV_VERSION = "0.13.6"
UV_SHA256 = "60fbd5c8a1ed681845eea28d9d622fcde03c51e91a43465b64a1e17db1ed3472"
RESERVE = 25 * 1024**3

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--bootstrap-only", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve(); root.mkdir(parents=True, exist_ok=True); os.chmod(root, 0o700)
    if shutil.disk_usage(root).free < RESERVE + 3 * 1024**3:
        raise RuntimeError("Preparing audio requires 3 GiB of working space plus the 25 GiB reserve.")
    binary = root / "uv"
    if not binary.exists():
        url = f"https://github.com/astral-sh/uv/releases/download/{UV_VERSION}/uv-aarch64-apple-darwin.tar.gz"
        with tempfile.TemporaryDirectory(dir=root) as folder:
            archive = Path(folder) / "uv.tar.gz"
            urllib.request.urlretrieve(url, archive)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != UV_SHA256: raise RuntimeError("Runtime bootstrap checksum mismatch")
            with tarfile.open(archive) as tar:
                member = next(m for m in tar.getmembers() if m.name.endswith("/uv") and m.isfile())
                with tar.extractfile(member) as source, binary.open("wb") as destination: shutil.copyfileobj(source, destination)
            os.chmod(binary, 0o700)
    env = {"HOME":str(Path.home()), "PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "UV_PYTHON_INSTALL_DIR":str(root / "Python"), "UV_CACHE_DIR":str(root / "Cache"), "UV_NO_PROGRESS":"1", "UV_LINK_MODE":"copy"}
    subprocess.run([str(binary), "python", "install", "3.12.12"], env=env, check=True)
    if not (root / "venv/bin/python").exists():
        subprocess.run([str(binary), "venv", "--python", "3.12.12", str(root / "venv")], env=env, check=True)
    if args.bootstrap_only: return
    lock = Path(__file__).with_name("requirements.lock")
    # Never leave a success receipt describing an environment that failed mid-update.
    (root / "runtime.json").unlink(missing_ok=True)
    subprocess.run([str(binary), "pip", "sync", "--python", str(root / "venv/bin/python"), "--require-hashes", "--only-binary", ":all:", str(lock)], env=env, check=True)
    (root / "runtime.json").write_text(json.dumps({"python":"3.12.12", "mlx-audio":"0.6.3", "mlx-vlm":"0.7.11", "lock":hashlib.sha256(lock.read_bytes()).hexdigest()}))
    os.chmod(root / "runtime.json", 0o600)

if __name__ == "__main__": main()
