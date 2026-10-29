# HTTP API

All routes require `Authorization: Bearer <key>`. POST requests require
`Content-Type: application/json`. Requests with browser `Origin` headers are
rejected. JSON errors have an `error` string. Responses use `Cache-Control: no-store`.

## GET /v1/models

Returns an array of `{id, capability, available, detail}`. Capabilities are
`generation`, `decision` or `embedding`. `apple` names the on-device Apple model. Ollama model
IDs are exact operator-enabled installed tags. A missing local runtime does not
hide Apple’s independent availability. Backend discovery is read-only.

## POST /v1/generate

```json
{"model":"apple","prompt":"Write a title.","instructions":"Be concise.","maxTokens":100}
```

`model` and `prompt` are required. `instructions`, `schema` and `maxTokens` are
optional. `think` may be a boolean, a model-supported level string, or null. Default maxTokens is 600; valid range is 1–4096. Prompt and instructions
together are limited to 64 KB. Models may enforce smaller context limits.

```json
{"model":"apple","text":"A Walking Journal","content":null,"usage":{"input_tokens":null,"output_tokens":null}}
```

With `schema`, `text` contains JSON and `content` contains the decoded value.
Apple’s supported subset includes objects with properties and required fields,
strings with optional enums, numbers, integers, booleans, arrays with item schemas
and optional minItems/maxItems, and nullable types on macOS 26.4 or later.
When `think` is omitted for Ollama, the service reads the model's advertised
thinking controls and requests no thinking output if that model supports it.
Otherwise it preserves the model default. Explicit `think: null` preserves the
model default, and a supported string requests that named level. Reasoning-only
or truncated output returns an actionable error instead of an empty success or
an invalid-request error. See [Ollama thinking controls](https://docs.ollama.com/capabilities/thinking).

Other JSON Schema constraints are not guaranteed by this initial API. Ollama
receives `schema` as its structured-output `format`. Consumers must validate any
application-specific constraints before acting on results.

## POST /v1/decisions

`/v1/systemone` is an alias. Send `{model, state, questions}`. Each question has
`type: "choice"`, nonempty `instructions`, and `criteria` mapping choice IDs to
descriptions. Supply 1–32 questions with 2–26 choices each. The encoded request
must fit 64 KiB. The selected model must be in the decision allowlist.

```json
{"model":"clef-flash:9b-mxfp8","answers":{"team":{"type":"choice","choice":"technical","probabilities":{"billing":0.01,"technical":0.99},"confidence":0.95}},"usage":{"input_tokens":80,"output_tokens":1}}
```

Answer keys and probability keys must exactly match the request. Probabilities
must be finite, lie in [0,1], sum to one within rounding tolerance, and assign the
selected choice a maximum probability. Confidence must be finite in [0,1]. Model
identity and nonnegative measured token usage are required. Failed validation is
an error; the app never substitutes a generative model or invents probabilities.

## POST /v1/embeddings

Send an enabled local embedding model and an array of 1–32 nonempty strings:

```json
{"model":"embeddinggemma:latest","input":["A walking journal","Notes from a hike"]}
```

Returns `{model, embeddings, usage}` with one finite numeric vector per input.
Vectors must have consistent dimensions, model identity must match, and measured
input-token usage must be supplied. Text inputs total at most 64 KB. The runtime
receives `truncate: false`; oversized model contexts fail instead of silently
truncating text. The Swift client exposes `ModelAPIClient.embed`.

Model discovery and downloads are app-only operator controls. API clients cannot
download weights, change model allowlists or select a cloud provider. Hosted
models and Apple Private Cloud Compute are outside Positronic's scope.

## Bounds and lifecycle

HTTP bodies are bounded to 1 MB, headers to 16 KiB, responses to 1 MB. Duplicate
headers, chunked request bodies and pipelined requests are unsupported. Up to 64
connections and four model/discovery requests can be active. Requests beyond
the inference limit return 429. The local Ollama request timeout is 115 seconds;
connections close after 130 seconds. Disconnect detection during inference is
best effort; stopping the API explicitly closes connections and cancels tasks.

The API has no retries, automatic paid fallback or automatic downloads. Caller
permissions, model routing and side effects belong to consuming systems. Use
separate named keys for those systems. Files are private to the signed-in macOS
user; another process with access to that user’s files shares that trust boundary.
