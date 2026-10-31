# Positronic

<img src="Assets/AppIcon.png" width="128" alt="Positronic icon">

A small native Mac app that makes local models and optional **Apple Private Cloud Compute** available to local scripts
and external systems through one authenticated HTTP API.

- **Apple Intelligence:** on-device generation through Apple Foundation Models,
  including structured output with a supported JSON Schema subset.
- **Apple Private Cloud Compute:** optional generation with light, moderate or deep reasoning on Apple’s servers, through an entitled macOS 27 build.
- **Local models:** generation through an operator-installed Ollama runtime.
- **Decision models:** typed choice questions through Ollama System One, including
  Clef-Flash and other installed compatible decision models. Responses preserve
  measured usage and validated probabilities.
- **Embeddings:** local text vectors for search, retrieval and similarity matching.
- **Audio:** English and Dutch transcription with Whisper Large V3 Turbo, and speech generation with Chatterbox Multilingual V3. Both run locally through a separate managed MLX-Audio worker.
- **Jobs:** a transient FIFO queue with one inference at a time, resource admission, cancellation and per-client result ownership.

One Swift executable contains the app and API. Create and revoke API keys in the
app, choose enabled models, and start or stop the service. A menu bar control keeps
it accessible after closing the window. Start at login and automatic API startup
are separate options. No model, runtime, paid service or remote-access service is
downloaded or provisioned automatically.

## Build and run

Requires macOS 26 or later, Xcode 26 or later, and an Apple Development signing
identity. Apple Intelligence additionally requires eligible hardware, region and
language, enabled Apple Intelligence, and its system model to be ready.

```sh
./script/build_and_run.sh
```

This builds and signs `dist/Positronic.app` and launches the bundle. The Codex
Run action uses this same script. Select a specific development identity with
`MODEL_API_SIGNING_IDENTITY`, or an ignored `Config/Signing.local` file. The native [Icon Composer](https://developer.apple.com/icon-composer/) document
`Assets/AppIcon.icon` compiles into `Assets.car`; macOS renders
its Liquid Glass edge and appearance variants. The softer illustrated brain is a
separate transparent PNG layer over the native gradient background. Extra
specular highlights are disabled on the brain to preserve its softer finish.
`script/build_icon.sh` exports the preview and compiler-generated ICNS fallback. The bundle
identity remains `nl.lucasilverentand.mac-model-api` across rebuilds. The script
also supports `build`, `--debug`, `--logs`, `--telemetry` and `--verify`.

Source compilation and tests do not require a signing identity:

```sh
swift build
swift test
```

## App pages

**Your models** shows all model types together in a searchable list. The selected model has its own test input and result alongside its memory, API access, load/unload and removal controls.
**Discover** is a separate searchable catalog with generation, decision, embedding, transcription and speech sections, plus a persistent download progress bar across pages.
**Jobs** shows queue positions, progress, resource waits and cancellation.
**API & Keys** controls serving and client credentials.
**Settings** contains startup, runtime and network options.
Downloads and model enable switches work while the API is running; changing a
model allowlist updates new requests without interrupting accepted work.

## Test a model where you manage it

Select any model in Your models. Its test panel is pinned to that exact model:

- Generation: enter a prompt and see or copy the response.
- Decisions: enter sample text, a question and choices, then inspect the selected choice, probabilities and confidence.
- Embeddings: enter texts on separate lines and inspect vector dimensions, a short vector preview and cosine similarity for the first two texts.
- Transcription: import or record audio, select English/Dutch, then copy the transcript and inspect timestamps.
- Speech: generate a short sample, play/stop it beside the model and export WAV.

Local tests use temporary operator access without enabling the model for API
clients or changing saved model choices. PCC still needs explicit operator
opt-in and its normal entitlement/quota checks. Models are never downloaded by a
test. Each model keeps its own temporary draft and result while you switch
selection. Cancellation and progress use the same resource-aware queue as API
requests. Results expire with their jobs; quitting discards them. Leaving a model
stops playback or an unfinished microphone recording; submitted work can finish
and remains visible in Jobs. The separate Playground and Audio testing pages have
been replaced by these model-specific panels.

## Local audio and temporary jobs

In Discover, explicitly **Prepare audio runtime**, download Whisper and/or Chatterbox,
then select one in Your models. Enable API access separately when clients need it. This installs a private, pinned Python/MLX-Audio
environment and immutable model revisions. No audio model is downloaded on demand.
After preparation, inference works offline. Audio never uses PCC or another cloud.
The worker starts only for admitted work and stops after five idle minutes.

Choose English or Dutch in the selected audio model’s test panel. Import up to 64 MiB / 30 minutes, or record the
microphone and stop to transcribe. Microphone permission is requested on Record;
denial leaves file import available. Speech takes up to 5,000 characters and uses
one packaged default voice. There is no reference-voice upload, cloning, music,
effects, diarization or live transcription. Export speech before results expire.

Model tests, explicit model loads and API inference share one FIFO scheduler.
At most 32 pending jobs are admitted. Resource checks and reservations are atomic
with scheduling, including on-demand loads. Jobs wait for normal memory pressure,
a model budget plus the greater of 2 GiB or 10% of physical RAM, CPU capacity and
safe thermal conditions. Unknown budgets wait instead of guessing. Owned idle
models can unload to make room; other applications are never interrupted.
Downloads preserve 25 GiB of free disk for installation/staging. Installed model
inference, uploads and result storage preserve 2 GiB plus their projected temporary
writes. This disk floor does not authorize swapping; RAM and active-swap checks
remain unchanged.

Available RAM includes reusable free pages, file-backed cache and volatile
purgeable pages. Speculative read-ahead pages are counted once. Inactive anonymous
app memory and compressed data are not counted as available: making room there
can require more compression or SSD swapping. Jobs shows this live breakdown,
system headroom, recent swap activity and the amount left for additional model
memory. Cache reclamation remains under macOS control; the app never runs purge
or forces other apps out. This is an estimate, not an OS memory reservation.
See [Apple’s VM counters](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h)
and [memory-pressure accounting](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md).

Waiting jobs recheck every two seconds and fail with a retryable explanation after
ten minutes. Running jobs are monitored each second; elevated memory pressure, thermal
emergency, reservation overrun, lost telemetry or 32 MiB of swap activity in
30 seconds stops work. Both swap-out writes and net swap growth are monitored,
so SSD churn is detected even when the swap-file size stays steady. Existing idle
swap alone does not block a job. These checks reduce risk but cannot prevent another app
from suddenly exhausting resources. Ollama budgets include weights, runtime and
an allowance for its bounded 8,192-token context; audio budgets include decoding
and worker overhead. Existing externally managed Ollama services need their own
context and parallelism limits.

Jobs and ownership metadata live in memory; inputs and results use private
temporary files. Inputs are deleted when work settles after completion or
cancellation. Results expire after 30 minutes. Quitting cancels work; restart
clears abandoned files and never replays jobs. Consuming apps own durable history,
restart recovery and retries. Revoking a key cancels its unfinished jobs. The
local operator can inspect and cancel all jobs.

See [the jobs and audio API](docs/API.md#asynchronous-jobs) and
[pinned audio provenance](Resources/Audio/README.md).

## Set up models

Apple availability appears automatically. Choose **Use installed Ollama** to connect to Ollama on this Mac, or enter another loopback runtime URL. The model library discovers installed models, reads their capabilities and offers explicit API enable switches. Open Discover for the Generation, Decisions and Embeddings sections; search by model name or type. Choose **Download** to install one through the local runtime, with progress and cancellation; enable it for API clients after installation. Starting the API and refreshing the list never download models. Cloud tags and discovered remote model aliases are excluded.

Use **Load** to prepare an installed model in memory, and **Unload** to release its memory while keeping its files. Memory status refreshes while the Models page is open; aliases sharing the same weights share this status. Enabled models reload on demand when requested by an API client. Explicit loads stay warm for up to 30 minutes, subject to runtime memory pressure and other requests; the prepared runtime allows one loaded model at a time.

Choose **Remove from Mac…** in a model’s menu to confirm deletion. The app disables that tag for API clients, unloads it, deletes it through the runtime and verifies it is gone. Shared files needed by other installed tags remain. A failed deletion stays disabled and reports an error. Management asks you to wait while API or model-test inference is in progress and is unavailable during downloads. Apple Intelligence is managed by macOS and has no app-level load or delete controls.

The model library includes Muse Glimmer 30B (4-bit), Qwen 3.5, Gemma 4, Llama 3.2, Mistral, DeepSeek R1 and Qwen Coder for generation; Clef, Clef Flash, Nimble and Tev1 for decisions; and EmbeddingGemma and Nomic Embed Text for embeddings. Any other compatible installed local model can be enabled using its exact tag under Advanced model tags. Model licenses and memory requirements are linked from each library entry. Downloaded weights remain outside Git and the app bundle.

For a fresh setup, choose **Prepare local runtime**. This explicitly downloads
the pinned Ollama 0.40.12 runtime, verifies its archive checksum and Apple
signature, and installs it in Positronic's private model folder. Model
weights remain a separate explicit download. Enable **Start my local runtime
when the app opens** to restore it before automatic API startup.

Alternatively, choose a prepared folder with `runtime/ollama` and `models/`, then
press **Start local runtime**. The app runs that binary on the configured loopback
port, disables Ollama cloud inference, and limits it to one loaded model and one
parallel request. The default backend port is 18768. Only the app’s own process
is stopped; another Ollama installation is never adopted or terminated. The
operator is responsible for the provenance of the binary and model licenses.
An existing service must separately be configured for local-only inference.

The prepared Clef-Flash asset folder from Seven can be selected directly; it is
not copied into the repository or app. This app uses its own backend port and
does not change Seven’s running local test service or operational model routing.
Avoid running multiple large models simultaneously on a memory-constrained Mac.

## Optional Apple Private Cloud Compute

PCC is a separate model, `apple-pcc`, and is off by default, including when loading older settings. Enable **Allow Private Cloud Compute** in the Private Cloud Compute detail pane under Your models when using a provisioned build. API clients must select `apple-pcc` explicitly; `apple` always uses the on-device model and Ollama tags retain their local routing. There is no automatic cloud fallback. A failed PCC request is returned as an error.

The PCC model’s test panel exposes light, moderate and deep reasoning. The API accepts `reasoningLevel` with the same values and defaults to `moderate`. Text and the supported structured-output schema subset are available. Model discovery labels execution as `local` or `applePrivateCloudCompute` and advertises PCC reasoning levels. Availability includes entitlement, OS readiness and Apple quota checks. Near-limit, quota-exhaustion, network and service failures have actionable messages. The app does not buy subscriptions or increase quota automatically; quotas and plan terms are controlled by Apple.

PCC requires **macOS 27**, a build made with **Xcode 27 / Swift 6.4 or later**, and Apple’s managed `com.apple.developer.private-cloud-compute` entitlement. Apple currently requires App Store Small Business Program enrollment, fewer than two million first-time app downloads, and entitlement approval. See [Apple’s eligibility and distribution requirements](https://developer.apple.com/private-cloud-compute/) for current terms and supported testing/distribution paths. Adding the entitlement locally cannot grant access.

After Apple grants access, register/enable PCC for the existing `nl.lucasilverentand.mac-model-api` identifier and obtain a macOS provisioning profile covering the signing certificate and this exact app. Keep the profile outside Git. Point the ignored `Config/Signing.local` at it, or supply:

```sh
MODEL_API_PCC_PROFILE='/absolute/path/to/approved.provisionprofile' ./script/build_and_run.sh --verify
```

The build script checks the profile’s PCC grant, exact application identifier, team, platform, expiration and signing certificate before stopping the running app. It then embeds the profile and signs with the required entitlements. Without that option, the normal signed local app still builds and runs, and PCC reports that its entitlement is missing. The approved-profile build path and live PCC inference must be verified once access is granted. Builds default to two compiler jobs; override with `MODEL_API_BUILD_JOBS` if needed.

## Call the API

Create a named key in the app and save it when displayed. Only a SHA-256 digest
is stored, in a private file under `~/Library/Application Support/MacModelAPI`.
Revocation rejects subsequent requests immediately; work already accepted can
finish. Stopping the API closes active client connections and cancels their work.
Prompts and generated responses are not stored by the app.

```sh
export MODEL_API_KEY='your-key-from-the-app'
curl http://127.0.0.1:18767/v1/models \
  -H "Authorization: Bearer $MODEL_API_KEY"

curl http://127.0.0.1:18767/v1/generate \
  -H "Authorization: Bearer $MODEL_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"apple","prompt":"Suggest a short title for a walking journal."}'

curl http://127.0.0.1:18767/v1/decisions \
  -H "Authorization: Bearer $MODEL_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"clef-flash:9b-mxfp8","state":"Checkout has returned 500 errors for an hour.","questions":{"team":{"type":"choice","instructions":"Which team should handle this?","criteria":{"billing":"Invoices and refunds","technical":"Software failures and outages"}}}}'
```

[`docs/API.md`](docs/API.md) describes request and response fields. The `ModelAPI`
Swift library provides `ModelAPIClient` for other apps. Seven connects over this
same API, retaining its own authorization, scheduling and model policy.

## Connect from another system

Local-only access is the default. Enable **Allow connections from other devices**
to bind the API to all IPv4 interfaces; clients then use your Mac’s private address
and port. Every endpoint requires a bearer key. The built-in transport is HTTP;
use a trusted encrypted private network or an operator-managed HTTPS proxy for
remote access. Networking, tunnels and public hosting are not managed by this app.
Browser-origin requests are rejected, and no permissive CORS policy is installed.

Text endpoints remain request/response. Batch audio and persistent local speech
sessions are available separately; see [Realtime speech](docs/Realtime.md) for the
authenticated streaming API and live model preview. Conversation context is
ephemeral and bounded. Positronic does not execute tools, silently fall back to
other models, store general cloud-provider credentials or download models automatically.
Unknown token usage is returned as null rather than estimated.

## Sources and license

MIT. Extracted reusable contracts are attributed in [NOTICE](NOTICE). Models and
runtimes retain their own licenses. Implementation follows Apple’s
[Foundation Models documentation](https://developer.apple.com/documentation/foundationmodels)
and Ollama’s [generation](https://docs.ollama.com/api/generate) and
[System One](https://docs.ollama.com/api/systemone) and [embeddings](https://docs.ollama.com/api/embed) contracts.

The Positronic rename retains the original bundle identifier and private data folder so existing settings, keys and signing trust remain valid.

## Live API check

After creating a client key in API & Keys and saving it in a private file, run:

```sh
python3 script/smoke_api.py --key-file /path/to/client.key
```

The check exercises authenticated discovery, Apple and Qwen structured generation,
Clef decisions and embedding batches using synthetic text. Model IDs can be
changed with its flags. It prints receipts and timings without printing the key
or vector contents. These are functional checks, not model-quality benchmarks.

After PCC is provisioned and enabled, add `--pcc --pcc-reasoning moderate` to explicitly include one structured cloud request. That consumes Apple daily quota; normal smoke runs never send cloud requests. The native app needs an active API key created by its operator for this test.

## Icon assets

`Assets/AppIcon.icon/Assets/Brain.png` is the independent transparent foreground item. Select “Brain · softer gloss” in Icon Composer to adjust its position, scale or material separately from the background. The original illustration reference remains in `Assets/AppIconArtwork.png`. Run `script/build_icon.sh` to export the preview and native ICNS fallback; the app build compiles the document into its asset catalog so macOS owns sizing, masking and adaptive appearances.

## Live model lifecycle check

With the private local runtime running and at least one installed model of each type:

```sh
POSITRONIC_LIVE_LIFECYCLE=1 swift test --filter LiveLifecycleTests
```

This creates temporary aliases for generation, decision and embedding models, then checks load, unload, inference after unload, reload and removal using the production service components. It removes only its temporary aliases and verifies the original model tags and digests remain. Synthetic prompts are used; this check does not create API keys or change app settings.

## Muse Glimmer compatibility

Discover includes `muse-glimmer:30b`, Ollama’s approximately 18 GB Q4_K_M build. Meta reports quantized Glimmer inference on an M4 Max; it is a plausible fit for a 36 GB M4 Max at a bounded context, subject to other apps and runtime overhead. This is distinct from Muse Spark Open, which is far too large for this machine. The owned runtime uses one loaded local model and an 8192-token context setting. A local download does not add tool execution or image input to Positronic’s text-only API.

The downloader requires projected model/staging space plus the 25 GiB download reserve. Discover shows the storage restriction and checks again before starting. Installed inference uses the separate 2 GiB working reserve plus projected temporary writes, with the same RAM and active-swap safeguards as other models. This guard is available when the model folder is configured; storage for an independently managed Ollama installation must be checked by its operator. Adding the preset does not download, enable or load it. Verify inference with a bounded context on the target Mac before relying on its throughput; a catalog entry does not establish a benchmark.

Sources: [Ollama tags](https://ollama.com/library/muse-glimmer/tags), [Meta’s Glimmer announcement](https://research.meta.ai/blog/introducing-muse-glimmer-open-agentic-model).

For a bounded check of already installed Muse weights, run
`POSITRONIC_LIVE_MUSE=1 swift test --filter LiveMuseTests` while no other local
model is in use. It uses the production memory/swap scheduler, a 32-token prompt
with reasoning disabled, and unloads afterward. A resource-blocked skip is not
an inference pass. It never downloads weights or changes API model choices.
