# Managed local audio

The operator explicitly installs a private CPython 3.12.12 environment using uv
0.13.6 (the bootstrap archive is checksum verified). `requirements.lock` pins
MLX-Audio 0.6.3 and every transitive Python dependency with wheel hashes. Only
binary wheels are allowed; nothing is installed into the system Python.

`models.json` pins immutable Hugging Face revisions for:

- [MLX Whisper Large V3 Turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo), plus the [OpenAI processor and tokenizer](https://huggingface.co/openai/whisper-large-v3-turbo).
- [MLX Chatterbox Multilingual V3](https://huggingface.co/mlx-community/chatterbox-multilingual-v3), [S3TokenizerV2](https://huggingface.co/mlx-community/S3TokenizerV2) and packaged default conditioning from [Chatterbox FP16](https://huggingface.co/mlx-community/chatterbox-fp16). Only conditioning is downloaded from the latter repository.

The Whisper MLX repository contains weights and configuration but lacks the
processor assets expected by MLX-Audio 0.6.3; these are installed from the pinned
OpenAI repository. The multilingual Chatterbox checkpoint lacks default voice
conditioning; the compatible upstream V2 conditioning supplies one fixed voice.
Callers cannot supply reference voices, paths or model revisions.

Installation records file hashes and sizes. Runtime verifies file availability
and sizes, requires the current dependency-lock digest, sets Hugging Face and
Transformers offline mode and blocks Python socket connections. A missing asset
fails the job; inference never installs or fetches anything. Deleting a model
removes its private assets while preserving dependencies still used by another
installed audio model.

The Swift scheduler owns resource admission and cancellation. The worker uses
JSON lines over private pipes, keeps one model resident, writes only inside the
private Jobs directory, and suppresses third-party prompt/audio diagnostics.
Audio limits and API ownership are enforced before scheduling. Worker failure
returns a generic error and removes partial output. SIGTERM receives a five-second
grace period before the app kills its own unresponsive worker.

Regenerate the lock deliberately with the pinned uv version:

```
uv pip compile requirements.in --python-version 3.12 --generate-hashes -o requirements.lock
```

Review changed dependency licenses, hashes and model provenance before updating.

## Full-duplex conversations

The explicit audio update additionally installs hash-locked MLX-VLM 0.7.11.
Nemotron VoiceChat 11B 4-bit uses its integrated LLM and Aria voice, English only,
with 16 kHz input and 22,050 Hz output. The pinned checkpoint bundles its tokenizer;
no second LLM or hosted service is used. See [realtime contracts](../../docs/Realtime.md).
