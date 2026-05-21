#!/usr/bin/env python3
"""
Convert NVIDIA NeMo TitaNet speaker verification model to Core ML.

The exported model keeps the same app contract as the previous speaker model:

  input:  raw 16 kHz mono waveform, float32 MLMultiArray [1, 48000]
  output: L2-normalized speaker embedding, float32 MLMultiArray [1, 192]

This allows the iOS app to keep its existing SpeakerEmbeddingModel wrapper while
using NVIDIA's TitaNet embeddings instead of the previous ECAPA export.

Usage:
  python tools/convert_titanet_to_coreml.py \
    --output CameraAccess/SpeakerEmbedding.mlpackage

Requirements:
  pip install "nemo_toolkit[asr]" coremltools torch numpy
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000
WINDOW_SAMPLES = 48_000
MODEL_NAME = "nvidia/speakerverification_en_titanet_large"
PREPROCESSING_VERSION = "titanet-raw-16khz-v1"


def load_titanet():
    from nemo.collections.asr.models import EncDecSpeakerLabelModel

    print(f"Loading {MODEL_NAME}...")
    model = EncDecSpeakerLabelModel.from_pretrained(MODEL_NAME)
    model.eval()
    print("TitaNet loaded.")
    return model


def trace_titanet(nemo_model, window_samples: int = WINDOW_SAMPLES):
    import torch
    import torch.nn as nn

    class TitaNetEmbeddingWrapper(nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, waveform):
            # waveform: [batch, time], raw 16 kHz float32 audio.
            lengths = torch.full(
                (waveform.shape[0],),
                waveform.shape[1],
                dtype=torch.int64,
                device=waveform.device,
            )
            _, embedding = self.model(input_signal=waveform, input_signal_length=lengths)
            norm = embedding.norm(dim=-1, keepdim=True).clamp(min=1e-8)
            return embedding / norm

    wrapper = TitaNetEmbeddingWrapper(nemo_model).eval()
    example = torch.zeros(1, window_samples, dtype=torch.float32)
    with torch.no_grad():
        # Warm NeMo's encoder length cache before tracing. TitaNet mutates an
        # internal max-sequence-length tensor on first use, which makes the
        # default trace sanity re-run compare two otherwise equivalent graphs.
        _ = wrapper(example)
        traced = torch.jit.trace(wrapper, example, strict=False, check_trace=False)
    return traced


def verify_torch_model(traced_model, window_samples: int = WINDOW_SAMPLES):
    import torch

    print("\nVerifying traced TitaNet model...")
    with torch.no_grad():
        embedding = traced_model(torch.randn(1, window_samples))
    norm = float(embedding.norm())
    print(f"  Output shape: {tuple(embedding.shape)}")
    print(f"  L2 norm: {norm:.6f}")
    if tuple(embedding.shape) != (1, 192):
        raise RuntimeError(f"Unexpected TitaNet embedding shape: {tuple(embedding.shape)}")
    if not np.isfinite(norm) or abs(norm - 1.0) > 1e-3:
        raise RuntimeError(f"Unexpected TitaNet embedding norm: {norm}")


def convert_to_coreml(traced_model, output_path: Path, window_samples: int = WINDOW_SAMPLES):
    import coremltools as ct

    print(f"\nConverting TitaNet to Core ML: {output_path}")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if output_path.exists():
        backup_path = output_path.with_name(f"{output_path.stem}.ecapa-backup{output_path.suffix}")
        if not backup_path.exists():
            print(f"Backing up existing model to {backup_path}")
            shutil.copytree(output_path, backup_path)
        shutil.rmtree(output_path)

    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.TensorType(name="waveform", shape=(1, window_samples), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT32,
    )

    mlmodel.short_description = (
        "NVIDIA NeMo TitaNet speaker embedding. "
        f"Input: raw 16 kHz mono float32 waveform [{window_samples} samples = 3 s]. "
        "Output: L2-normalized 192-dim speaker embedding."
    )
    mlmodel.author = "NVIDIA NeMo TitaNet, converted for MetaFace"
    mlmodel.version = "1"
    mlmodel.user_defined_metadata["source"] = MODEL_NAME
    mlmodel.user_defined_metadata["preprocessingVersion"] = PREPROCESSING_VERSION
    mlmodel.user_defined_metadata["embeddingDimension"] = "192"
    mlmodel.user_defined_metadata["sampleRate"] = str(SAMPLE_RATE)
    mlmodel.user_defined_metadata["windowSamples"] = str(window_samples)

    mlmodel.save(str(output_path))
    print(f"Saved Core ML TitaNet model to {output_path}")


def verify_coreml_model(output_path: Path, window_samples: int = WINDOW_SAMPLES):
    import coremltools as ct

    print(f"\nVerifying Core ML model at {output_path}...")
    model = ct.models.MLModel(str(output_path))
    rng = np.random.default_rng(42)
    waveform = rng.standard_normal((1, window_samples)).astype(np.float32)
    output = model.predict({"waveform": waveform})["embedding"]
    norm = float(np.linalg.norm(output))
    print(f"  Embedding shape: {output.shape}")
    print(f"  L2 norm: {norm:.6f}")
    if output.shape != (1, 192):
        raise RuntimeError(f"Unexpected Core ML embedding shape: {output.shape}")
    if not np.isfinite(norm) or abs(norm - 1.0) > 1e-3:
        raise RuntimeError(f"Unexpected Core ML embedding norm: {norm}")


def main():
    parser = argparse.ArgumentParser(description="Convert NVIDIA NeMo TitaNet to Core ML")
    parser.add_argument("--output", default="CameraAccess/SpeakerEmbedding.mlpackage")
    parser.add_argument("--window-seconds", type=float, default=3.0)
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args()

    window_samples = int(round(args.window_seconds * SAMPLE_RATE))
    output_path = Path(args.output)

    nemo_model = load_titanet()
    traced_model = trace_titanet(nemo_model, window_samples)
    if not args.skip_verify:
        verify_torch_model(traced_model, window_samples)
    convert_to_coreml(traced_model, output_path, window_samples)
    if not args.skip_verify:
        verify_coreml_model(output_path, window_samples)


if __name__ == "__main__":
    main()
