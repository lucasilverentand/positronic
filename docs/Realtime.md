# Local realtime speech

Positronic exposes authenticated **WebSocket `/v1/realtime`**, protocol version 1.
It uses one native full-duplex Nemotron VoiceChat model: speech perception, its
Nemotron LLM, and the built-in Aria voice advance together every 80 ms. Incoming
microphone frames continue while it generates speech. This is not a configurable
Whisper → Ollama → Chatterbox pipeline, and does not use Apple PCC or a hosted LLM.

The initial checkpoint is **English only**. Existing English/Dutch batch audio
endpoints are unchanged. A streaming transport does not establish ChatGPT-level
quality, interruption behavior or measured realtime speed on a particular Mac.

## Install explicitly

1. In Settings, choose **Prepare audio update**. This installs hash-locked
   MLX-Audio 0.6.3 and MLX-VLM 0.7.11 with managed CPython 3.12.12.
2. In Discover → Conversation, download **Nemotron VoiceChat · 11B · 4-bit**.
   The approximately 9.2 GB checkpoint and its tokenizer are pinned to
   `dffd203fef7a380081da89479c55848e50b98413`. No separate LLM weights are fetched.
3. Try the live preview beside the model, or enable its API access in Your models.
   A local preview does not change API access or persisted operator choices.

For downloads, keep 25 GiB free after projected writes. Installed inference uses\na separate 2 GiB floor plus projected temporary writes; RAM and swap safeguards\nremain unchanged. Discover conservatively requires 10 GiB
of download space in addition to that reserve. The installer checks actual pinned
asset sizes before downloading. Downloads and runtime updates are never implicit.
Old, pinned batch-audio environments remain usable until explicitly updated.
The worker blocks network connections and uses only prepared local assets.

## Connect and configure

Use the API's existing address and an `Authorization: Bearer …` header. The
server rejects browser Origin headers and query-string credentials. Compression
may be offered by a client but is not negotiated. Frames must be masked; fragmented
JSON text is supported up to 64 KiB. Binary messages are not accepted.

The server first sends `session.created`. Within ten seconds send:

```json
{
  "type": "session.configure",
  "session": {
    "model": "nemotron-voicechat-11b-4bit",
    "instructions": "Be helpful and concise.",
    "language": "en",
    "maxDurationSeconds": 300
  }
}
```

Instructions are limited to 1024 UTF-8 bytes. Sessions last 10–600 seconds, default
300; at the limit, reconnect with a fresh context. This bounds growing model caches.
No conversation history is replayed automatically or saved durably.

`session.queued` returns the normal job metadata and ID. `session.status` reports
queue/resource/loading changes, including required versus available memory and
specific waiting reasons. **Wait for `session.ready` before sending microphone
frames.** Microphone capture in the native preview begins only after admission.

## Continuous input and output

Send one frame at a time, paced at 80 ms:

```json
{"type":"input_audio.append","audio":"<base64 PCM16LE>"}
```

Each input frame is exactly **1280 samples / 2560 bytes**, **16 kHz, mono, signed
16-bit little-endian**. Send captured silence too: it represents the live timeline
and lets the model keep responding between utterances. The server advances with
silence if a frame is missing, but closes after ten seconds without microphone
input. It never replays an unlimited backlog of old frames to catch up.

| Server event | Payload / client behavior |
| --- | --- |
| `session.ready` | `sampleRate: 16000`, `frameSamples: 1280`; start capture |
| `input_audio.transcript.delta` | `delta`: incremental recognized user text |
| `response.text.delta` | `delta`: incremental assistant text |
| `output_audio.delta` | `audio`: 1764 PCM16LE samples, 22,050 Hz mono; `sequence`, `epoch` |
| `input_audio.speech_started` / `speech_stopped` | Server's basic energy-based speech detection |
| `output_audio.clear` | Immediately discard queued playback; switch to the new `epoch` |
| `session.done` | Duration reached or input committed; fresh session required |
| `session.error` | Error/resource cancellation detail; stop capture/playback |

**Acknowledge audio after playback, not merely after receipt:**

```json
{"type":"playback.ack","sequence":12,"epoch":1}
```

Sequence numbers increase across the whole session. The epoch changes when
playback is cleared. Do not play frames from an earlier epoch; acknowledgements
from old epochs are ignored. The server permits at most 25 unacknowledged output
frames (two seconds). Slow or stalled playback terminates the session.

Use echo-cancelled microphone input or headphones. Two energetic input frames
(160 ms) clear queued playback and suppress output during speech; four quiet
frames (320 ms) permit speech output again. The model continues consuming audio
and updating its native conversation state during this suppression. This detector
is intentionally simple: noise, quiet speech and echo can affect it. The model's
semantic response to an interruption still needs listening-quality validation.

Client controls:

- `response.cancel`: clear playback immediately and suppress output until the next
  detected speech onset; the model keeps listening and retains its context.
- `input_audio.commit`: finish after already buffered input is processed.
- `session.cancel` or close the WebSocket: cancel the entire job and unload the
  owned worker; close also cancels queued sessions.
- `session.ping`: receive `session.pong`.

Model function-channel output is not executed. This API does not grant tools or
perform actions on behalf of consuming apps.

## Swift client

`ModelAPI.RealtimeConnection` uses an ephemeral URLSession with redirects and
proxy forwarding disabled, and never persists the bearer key:

```swift
let connection = try RealtimeConnection(baseURL: apiURL, apiKey: key)
_ = try await connection.receive() // session.created
try await connection.configure(.init(instructions: "Keep replies short."))
// Receive events continuously. Start a separate capture task on session.ready:
try await connection.appendAudio(pcm16Frame) // exactly 2560 bytes
// Queue output_audio.delta for playback, respecting epoch and output_audio.clear.
// In each playback completion callback:
try await connection.acknowledge(sequence, epoch: epoch)
// Stop capture and release the connection when the consumer exits:
await connection.close()
```

Continue receiving while capture sends frames; do not wait for an entire answer.
Use TLS (`https` base URL becomes `wss`) or an encrypted trusted network for remote
clients. Network binding and API key behavior match the existing API.

## Resource and ownership contract

Each session owns one FIFO inference job. Its monitored ceiling starts with the
installed weight bytes, 2.25 GiB for runtime/activation/decoding overhead, and
4 MiB per second of requested duplex context. A 16 GiB fallback applies when
installed asset metadata is unavailable. The ceiling is checked against actual
owned memory use, not demanded in full before the first allocation.

The managed worker loads lazily, requests scheduler permission before evaluating
small weight groups, and checks again before session initialization and each live
step. Initial admission reserves a 512 MiB loading step plus system headroom.
Denied growth waits safely; normal pressure, low swap activity, thermal/CPU and
disk checks remain enforced. Jobs distinguishes the next allocation requirement
from the estimated full peak. MLX's allocator memory-limit API is advisory; it is
not used as a hard safety boundary. The worker's reusable allocator cache is
limited to 128 MiB. System headroom is added by the existing atomic scheduler. No other
inference or explicit Load runs alongside it; other jobs remain queued.

Admission requires normal memory pressure, low swap traffic, adequate RAM after
reclaimable cache accounting, thermal/CPU capacity and the disk reserve. Unknown
budgets wait safely. Resource waits expire after ten minutes. The existing
once-per-second monitor cancels at elevated memory pressure, reservation overrun,
32 MiB recent swap activity, critical thermal state or lost telemetry. Worker
termination gets the existing five-second grace, then SIGKILL if unresponsive.

Only Positronic-owned idle models may be unloaded. No other application's runtime
or process is stopped. Input and output queues are each bounded to two seconds;
old input, slow output and network write stalls close the session. These checks
reduce risk but cannot prevent unrelated applications from exhausting resources.

Keys own their jobs; normal `/v1/jobs/{id}` status/cancellation, key isolation and
revocation also cover realtime jobs. The local operator can cancel a session in
Jobs. Audio and transcript contents remain in bounded process memory, not job
files. Completed job results contain only an ended status. Restart discards all
sessions; consumers own durable history and reconnect behavior.

## Validation boundary

Deterministic tests exercise RFC framing, the Swift WebSocket client, streaming
fixtures, disconnect cancellation, per-key queue access/revocation, resource
blocking and interruption epochs without loading model weights. Physical-Mac
model throughput, sustained memory use, audible quality, echo handling and native
microphone permission paths require separate live acceptance. Do not substitute
these transport fixtures for an actual realtime-model inference receipt.

Sources: [pinned checkpoint](https://huggingface.co/mlx-community/NemotronLabs-VoiceChat-11B-4bit/tree/dffd203fef7a380081da89479c55848e50b98413),
[MLX-VLM](https://github.com/Blaizzy/mlx-vlm),
[MLX-Audio](https://github.com/Blaizzy/mlx-audio).

## Bounded physical-Mac check

With the app stopped, one shared heavy-work lease held, and the runtime/model
explicitly installed, run:

```sh
POSITRONIC_LIVE_REALTIME=1 \
POSITRONIC_LIVE_REALTIME_OUTPUT=/private/tmp/positronic-live-conversation \
swift test --jobs 2 --filter LiveRealtimeTests.testNativeDuplexConversationOverStreamingAPI
```

The opt-in check establishes a 30-second swap window, applies the production
staged admission and the measured-memory ceiling, creates two spoken prompts locally, and connects the
real Swift client to an authenticated temporary instance of the production router.
It streams live-paced PCM, interrupts the first answer, asks a follow-up question,
saves generated WAV audio and transcribes that output locally. A telemetry receipt
records pressure, memory, disk, swap activity and worker RSS. The live stream is
bounded to 40 seconds and the whole attempt has a three-minute deadline. Inference
never starts if admission is blocked; a resource skip is not a conversation pass.
Temporary keys and API allowlists do not change the operator's configuration.

## Learning from model runs

Positronic stores aggregate resource observations in its private
`resource-profiles.json`: peak owned memory, completed/failed/cancelled counts,
processed context and live-frame processing time. The model's detail pane shows
observed peaks and frame timings. No prompt, transcript, audio or API key is saved
in this profile store.

Observations are separated by model revision, runtime/dependency identity and
worker implementation, and operation. Three completed runs with a sufficiently long observed context can
supply a future sizing estimate, retaining 25% plus 512 MiB above the largest
successful peak and an installed-weight floor. Short runs do not establish memory
requirements for longer conversations. A later failure suspends downward tuning;
failed observed peaks can only raise the ceiling. Incomplete runtime observations
are displayed but never used to lower a budget. Blocked jobs with no measured work
are not sizing evidence. Live pressure/swap/disk checks always apply regardless of
learned estimates. Stores with invalid content are preserved rather than replaced.

The pinned worker restores checkpoint BF16 precision at the ASR encoder and TTS
input boundaries, avoiding unintended FP32 promotion. FP32 preprocessing, sampling
noise and required SSM state remain intact. Small feed-forward graphs and the full
fixed ASR attention window are compiled with numerical checks and an original-path
fallback. Sampling explicitly advances MLX random state. The causal speech encoder
warms on silence before `session.ready`; this does not advance conversation output.

After input commit, final playback acknowledgements have a bounded two-second
drain before `session.done` and transport closure. A slow or missing playback
acknowledgement fails safely rather than accumulating audio.


## Independent local microphone cleanup

The Mac preview defaults to **Echo cancellation** and **Voice focus**. Both can be
changed while stopped. Echo cancellation uses bundled SpeexDSP; voice focus uses
the embedded RNNoise neural denoising network. These CPU processors work offline
without Apple Voice Isolation, Apple voice-processing IO, PCC, an account or an
additional model download. Core Audio remains the Mac device transport.

The echo reference comes from the app's actual rendered playback, including clears,
rather than merely from generated text/audio that may never reach the speakers.
Microphone and reference buffers are copied while the hardware owns them, then
converted and processed on one bounded serial queue. Processing uses 10 ms mono
48 kHz blocks, then resamples to the model's 16 kHz PCM. Model-facing frames stay
80 ms. The resampling filter has a short initial priming delay. The device handoff reserves duration and bytes atomically: at most two seconds
per direction, 4 MiB combined and 256 small packets. This accepts legitimate
640 ms device bursts without confusing 10 ms device packets with 80 ms API
frames. Input blocks larger than 16,384 frames, invalid layouts or nonfinite
samples fail safely; API input/output retain their existing two-second bounds.
A two-second speaker-reference history and bounded 120 ms near-audio alignment
allow the canceller to match batched render taps by host timestamp. The 120 ms
alignment is additional latency when echo cancellation is enabled.

Voice focus reduces background noise; it does not identify a particular speaker or
promise to remove another person's speech. Echo cancellation adapts to the room and
speaker delay, so fixture attenuation is not a guarantee for every physical setup.
Headphones remain useful for difficult acoustic environments.

The microphone uses a persistent input queue with three fixed 10 ms buffers;
playback does not open or reconfigure a microphone. A silent render source keeps\nthe selected speaker clock active through model loading and listening. Both remain open across
speech, silence and interruption. Low-latency scheduling is active only during
the session and ends on stop. Audio setup runs on its own actor after shared-scheduler admission and before model
warmup. Capture is paused during loading: old microphone samples are discarded, not
replayed when the model becomes ready. The preview shows listening only after a
cleaned live frame is accepted. It waits for user speech before advancing the model.
RAM, swap, thermal, CPU, disk and telemetry safeguards remain active. Playback waits
for an IO clock; macOS 27 uses the throwing playback API so a missing IO cycle can
fail the job rather than raise an uncaught playback exception.

External API consumers still own their capture/playback path and echo reference;
the host cannot infer the sound rendered on a different device from playback ACKs.
These preview controls do not change external client PCM or API model access.
Clients can reuse the optional `PositronicVoiceDSP` C library product with their own
actual playback reference. Its caller serializes per-stream state; render/capture
blocks are 480 float samples at 48 kHz, and capture returns up to 160 samples at
16 kHz (shorter during initial resampler priming).

Bounded explicit developer checks, after building the signed app:

- `--check-realtime-audio`: three microphone/silent-playback/reset cycles; no model.
- `--check-continuous-audio`: one uninterrupted 20-second input/playback/reset check.
- `--check-continuous-preview`: one admitted model/microphone session held live for
  30 seconds after the first cleaned frame is accepted.
- `--check-realtime-preview`: three admitted real conversation model/microphone
  starts and stops, with a 40-second startup bound per attempt. This loads the
  installed model, asks for normal microphone permission and never downloads one.

Only readiness/count metadata is logged by these checks. No microphone recordings
or transcripts are saved. These flags are process-local and do not affect normal
launches. Upstream revisions, source hashes and licenses are in
`ThirdParty/README.md`; audio signal and background-thread ownership checks live in
`LocalVoiceDSPTests` and `RealtimeCaptureTests`.
