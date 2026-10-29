# Purple Matter

<img src="Assets/AppIcon.png" width="128" alt="Purple Matter icon">

A small native Mac app for **local models only** that makes the models on your Mac available to local scripts
and external systems through one authenticated HTTP API.

- **Apple Intelligence:** on-device generation through Apple Foundation Models,
  including structured output with a supported JSON Schema subset.
- **Local models:** generation through an operator-installed Ollama runtime.
- **Decision models:** typed choice questions through Ollama System One, including
  Clef-Flash and other installed compatible decision models. Responses preserve
  measured usage and validated probabilities.
- **Embeddings:** local text vectors for search, retrieval and similarity matching.

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

This builds and signs `dist/Purple Matter.app` and launches the bundle. The Codex
Run action uses this same script. Select a specific development identity with
`MODEL_API_SIGNING_IDENTITY`, or an ignored `Config/Signing.local` file. The bundle
identity remains `nl.lucasilverentand.mac-model-api` across rebuilds. The script
also supports `build`, `--debug`, `--logs`, `--telemetry` and `--verify`.

Source compilation and tests do not require a signing identity:

```sh
swift build
swift test
```

## Set up models

Apple availability appears automatically. Choose **Use installed Ollama** to connect to Ollama on this Mac, or enter another loopback runtime URL. The model library discovers installed models, reads their capabilities and offers explicit API enable switches. Browse Generation, Decisions and Embeddings for additional models. Choose **Download** to install one through the local runtime, with progress and cancellation; enable it for API clients after installation. Starting the API and refreshing the list never download models. Cloud tags and discovered remote model aliases are excluded.

The initial library includes Qwen 3.5, Gemma 4, Llama 3.2, Mistral, DeepSeek R1 and Qwen Coder for generation; Clef, Clef Flash, Nimble and Tev1 for decisions; and EmbeddingGemma and Nomic Embed Text for embeddings. Any other compatible installed local model can be enabled using its exact tag under Advanced model tags. Model licenses and memory requirements are linked from each library entry. Downloaded weights remain outside Git and the app bundle.

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

The initial API is nonstreaming, text-only and stateless. It does not execute
tools or maintain chat history. It has no silent model fallback, Private Cloud
Compute integration, cloud provider credential store or automatic model downloads.
Unknown token usage is returned as null rather than estimated.

## Sources and license

MIT. Extracted reusable contracts are attributed in [NOTICE](NOTICE). Models and
runtimes retain their own licenses. Implementation follows Apple’s
[Foundation Models documentation](https://developer.apple.com/documentation/foundationmodels)
and Ollama’s [generation](https://docs.ollama.com/api/generate) and
[System One](https://docs.ollama.com/api/systemone) and [embeddings](https://docs.ollama.com/api/embed) contracts.

The Purple Matter rename retains the original bundle identifier and private data folder so existing settings, keys and signing trust remain valid.
