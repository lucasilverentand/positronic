#!/usr/bin/env python3
"""Run with the explicit audio Python; uses tiny arrays, never model weights."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Resources/Audio"))
import mlx.core as mx
import mlx.nn as nn
from realtime_optimizations import CompiledFeedForward, CastInput, CastOutput, compile_sampler

class RealtimeOptimizationTests(unittest.TestCase):
    def test_feed_forward_numerics_and_parameters_are_preserved(self):
        mx.random.seed(1)
        layer = nn.Sequential(nn.Linear(16, 32), nn.SiLU(), nn.Linear(32, 16))
        layer.eval(); compiled = CompiledFeedForward(layer)
        for x in [mx.ones((1,1,16)), mx.random.normal((1,1,16))]:
            self.assertTrue(bool(mx.allclose(layer(x), compiled(x), atol=1e-6)))
        from mlx.utils import tree_flatten
        original = sum(v.nbytes for _,v in tree_flatten(layer.parameters()))
        retained = sum(v.nbytes for _,v in tree_flatten(compiled.parameters()))
        self.assertEqual(original, retained)
    def test_checkpoint_precision_is_not_promoted_by_float32_inputs(self):
        layer = nn.Linear(8, 8); layer.set_dtype(mx.bfloat16)
        x = mx.ones((1,1,8), dtype=mx.float32)
        self.assertEqual(layer(x).dtype, mx.float32)
        restored = CastInput(layer, mx.bfloat16)
        self.assertEqual(restored(x).dtype, mx.bfloat16)
        self.assertTrue(bool(mx.array_equal(restored(x), layer(x.astype(mx.bfloat16)))))
        cast_output = CastOutput(layer, mx.bfloat16)
        self.assertEqual(cast_output(x).dtype, mx.bfloat16)
    def test_sampler_preserves_and_advances_random_state(self):
        def sample(x): return x + mx.random.normal(x.shape)
        compiled = compile_sampler(sample); x = mx.ones((1,1,16))
        mx.random.seed(3); reference = sample(x); mx.eval(reference)
        mx.random.seed(3); candidate = compiled(x); mx.eval(candidate)
        self.assertTrue(bool(mx.array_equal(reference, candidate)))
        following = compiled(x); mx.eval(following)
        self.assertFalse(bool(mx.array_equal(candidate, following)))

if __name__ == "__main__": unittest.main()
