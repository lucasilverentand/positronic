"""Inference-only fusion for the pinned VoiceChat runtime; sampling is unchanged."""
import mlx.core as mx
import mlx.nn as nn


class CompiledFeedForward(nn.Module):
    def __init__(self, module):
        super().__init__()
        self.original = module
        self.forward = mx.compile(lambda x: module(x))

    def __call__(self, x):
        return self.forward(x)


class CastInput(nn.Module):
    def __init__(self, module, dtype):
        super().__init__(); self.original = module; self.dtype = dtype
    def __call__(self, x, *args, **kwargs):
        return self.original(x.astype(self.dtype), *args, **kwargs)


class CastOutput(nn.Module):
    def __init__(self, module, dtype):
        super().__init__(); self.original = module; self.dtype = dtype
    def __call__(self, *args, **kwargs):
        return self.original(*args, **kwargs).astype(self.dtype)


def compile_sampler(function):
    # Random state is an explicit graph input/output. Capturing a fixed seed would
    # silently repeat sampling noise and change the model's behavior.
    return mx.compile(function, inputs=mx.random.state, outputs=mx.random.state)


def optimize_model(model):
    perception = getattr(getattr(model, "stt_model", None), "perception", None)
    if perception is None:
        return 0
    dtype = perception.proj.weight.dtype
    # Log-mel features are correctly computed in FP32, but the checkpoint's
    # encoder weights are BF16. Otherwise mixed inputs promote every encoder
    # layer to FP32 and re-cast weights on each live frame.
    perception.encoder.pre_encode = CastInput(perception.encoder.pre_encode, dtype)
    probe = mx.zeros((1, 1, perception.encoder.args.d_model), dtype=dtype)
    fused = 0
    for block in perception.encoder.layers:
        for name in ("feed_forward1", "feed_forward2"):
            original = getattr(block, name)
            compiled = CompiledFeedForward(original)
            reference = original(probe); candidate = compiled(probe)
            mx.eval(reference, candidate)
            if bool(mx.allclose(reference, candidate, atol=1e-2, rtol=1e-2)):
                setattr(block, name, compiled); fused += 1
    tts = model.tts_model.tts_model
    tts_dtype = tts.backbone.layers[0].mlp.gate_proj.weight.dtype
    # The port starts RVQ sums/text buffers with default-FP32 zeros. Restore
    # checkpoint precision at linear/backbone boundaries, retaining FP32 audio
    # preprocessing, sampler noise and the model's required FP32 SSM state.
    tts.embed_code = CastInput(tts.embed_code, tts_dtype)
    tts.gated_fusion_audio_text = CastOutput(tts.gated_fusion_audio_text, tts_dtype)
    tts.generate_codes = compile_sampler(tts.generate_codes)
    for layer in tts.backbone.layers:
        original = layer.mlp
        compiled = CompiledFeedForward(original)
        sample = mx.zeros((2, 1, tts.config.hidden_size), dtype=dtype)
        reference = original(sample); candidate = compiled(sample); mx.eval(reference,candidate)
        if bool(mx.allclose(reference,candidate,atol=1e-2,rtol=1e-2)):
            layer.mlp = compiled
    enable_fixed_context_perception()
    return fused


def enable_fixed_context_perception():
    """Fuse pure encoder blocks only at the fixed, fully populated cache shape.

    Short caches retain the original path. No unbounded graph variants are
    compiled while the attention window grows during startup.
    """
    from mlx_audio.stt.models.nemotron_asr import streaming
    original = streaming._stream_block
    compiled_blocks = {}

    def dispatch(block, x, pos_enc, attn, conv, left, conv_left):
        if attn is None or conv is None or attn.shape[1] != left or x.shape[1] != 1:
            return original(block, x, pos_enc, attn, conv, left, conv_left)
        key = id(block)
        if key not in compiled_blocks:
            def operation(value, attention, convolution):
                return original(block, value, pos_enc, attention, convolution, left, conv_left)
            function = mx.compile(operation)
            reference = operation(x, attn, conv); candidate = function(x, attn, conv)
            mx.eval(*reference, *candidate)
            matches = all(bool(mx.allclose(a, b, atol=1e-2, rtol=1e-2)) for a,b in zip(reference,candidate))
            compiled_blocks[key] = function if matches else operation
            return candidate if matches else reference
        return compiled_blocks[key](x, attn, conv)

    streaming._stream_block = dispatch


def warm_perception(session, checkpoint):
    # Prime only the causal speech encoder with real silence. Language, speech
    # generation and the public frame counter stay untouched. This gives the
    # compiler one fixed attention-cache shape before live audio is accepted.
    stream = getattr(session, "_conformer_stream", None)
    if stream is None:
        return
    silent = mx.zeros((session.frame_samples,), dtype=mx.float32)
    for index in range(stream.left_cache + 1):
        if index % 8 == 0:
            checkpoint(128 * 1024**2)
        session._perception_step(silent)
