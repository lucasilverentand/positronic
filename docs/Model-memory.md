# Local model memory estimates

An admission estimate is a model working-set budget, plus separate system
headroom. It is not a measured model requirement and is not an OS reservation.
Do not count anonymous/compressed memory as reclaimable or relax memory pressure,
active-swap, thermal, CPU or telemetry checks to make an estimate fit.

## Muse Glimmer Q4

The supported Muse GGUF shape is checked against `/api/show`: 52 layers, two KV
heads, 128 key/value dimensions, embedding width 6656 and feed-forward width
19968. Unknown formats, quantizations, shapes or missing metadata retain the
conservative generic fallback. Other model families are unchanged.

`OllamaMemoryEstimate` separates:

- Weights: the installed byte size reported by the runtime, counted once.
- FP16 KV cache: `context × layers × KV heads × (key width + value width) × 2`.
  Count every layer; do not assume sliding-window or quantized-cache savings.
- Runtime, graph and activation workspace: one 2 GiB allowance at batch <=128.
  This is a provisional allowance, not a measured upper bound.
- Safety margin: greater of 512 MiB or 5% of installed weights.

This replaces the overlapping generic `weights × 1.35 + 2 GiB` allowances only
for the supported Muse path. The workspace and margin still need physical-run
calibration; metadata does not provide an exact Metal compute-graph peak.

The installed 18,157,010,252-byte model with a 1,024-token context has a calculated
54,525,952-byte KV cache and a 21,266,870,364-byte model budget (about 19.8 GiB).
Adding existing 3.6 GiB system headroom on a 36 GiB Mac gives about 23.4 GiB for
admission. The default 8,192-token context has a larger cache and budget.

Generation requests explicitly send `num_ctx` and `num_batch=128`; the estimate
and execution use the same context bound. Explicit generation-model loads use
8,192/128 too. The short Muse check constructs its engine with a 1,024-token
context, disables reasoning and allows only 32 output tokens. Limiting output
alone does not reduce an already allocated context cache.

Run `POSITRONIC_LIVE_MUSE=1 swift test --filter LiveMuseTests` for an explicit,
bounded check of existing installed weights. The production scheduler checks
resources again before running, monitors each second, and unloads after the test
or cancellation. A preflight skip is not a successful inference run. Never lower
an estimate from a skipped, failed or cancelled run.

Sources: runtime `/api/tags` and `/api/show` metadata; Ollama's
[generation API](https://docs.ollama.com/api/generate) and
[runtime parameters](https://docs.ollama.com/modelfile#valid-parameters-and-values).
Implementation: `Sources/ModelService/OllamaMemoryEstimate.swift`,
`ModelEngine.swift`, `ModelManager.swift`. Regressions verify cache arithmetic,
unsupported metadata and execution bounds.

## Bounded loading observation — 2026-10-31

An explicitly requested one-off observation bypassed only the static estimate;
production policy was unchanged. The installed Muse checkpoint was requested with
1,024 context tokens, batch 128, 32 output tokens, reasoning disabled and no
keep-alive. The monitor retained normal-pressure admission, system headroom,
active-swap, thermal, CPU and timeout cancellation.

At start, available RAM including reclaimable cache was 15,787,130,880 bytes
(about 14.7 GiB), below the component estimate. At one second it fell to
4,679,565,312 bytes with normal pressure and no new swap writes. At two seconds
pressure rose to warning and available RAM fell to 3,573,940,224 bytes. The monitor
cancelled the request and explicitly unloaded the model. Cleanup finished about
2.24 seconds after start; pressure returned to normal and `/api/ps` was empty.
No generated answer was received.

Kernel swap-out writes increased by 736,493,568 bytes (about 702 MiB) before
cancellation finished. This failed the no-swap acceptance target. One-second
monitoring detected the problem but could not prevent the initial allocation
burst. Never describe this as a successful inference or as proof the guard can
prevent all SSD writes. No model-specific peak working set was measured; the
available-memory decrease includes system-wide activity and is not a valid peak
profile or evidence for reducing the model budget.

Keep upfront model-memory admission in production. Do not automatically retry or
apply audio-worker staged admission to Ollama's monolithic loading path: it does
not expose Positronic's per-allocation checkpoints. Actual prompt acceptance
remains open until enough memory is released by other applications. Existing idle
swap may remain afterward; active swap traffic, not simply file size, governs
subsequent admission.
