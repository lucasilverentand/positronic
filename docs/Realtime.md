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

Keep 25 GiB free after projected writes. Discover conservatively requires 10 GiB
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

Each session owns one FIFO inference job and a conservative **16 GiB model budget**
for quantized weights, perception/LLM/TTS/codec caches, decoding and Python/runtime
overhead. System headroom is added by the existing atomic scheduler. No other
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
