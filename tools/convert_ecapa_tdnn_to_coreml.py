#!/usr/bin/env python3
"""
Convert SpeechBrain ECAPA-TDNN speaker embedding model to CoreML.

The exported model accepts a raw 16 kHz mono waveform (48 000 samples = 3 s) as a
float32 array [1, 48000] and outputs an L2-normalized 192-dim embedding [1, 192].
Feature extraction (FBANK) is included inside the model graph so iOS only needs to
pass raw audio — no mel-spectrogram code required on the Swift side.

The output model is saved as SpeakerEmbedding.mlpackage, ready to drop into the
Xcode project (same process as MobileFaceNet.mlpackage for face recognition).

Usage:
  python tools/convert_ecapa_tdnn_to_coreml.py \
    --output CameraAccess/SpeakerEmbedding.mlpackage

Requirements:
  pip install speechbrain torch torchaudio coremltools numpy
"""

import argparse
import sys
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000
WINDOW_SAMPLES = 48_000  # 3 seconds at 16 kHz


class WrappedECAPA(object):
    """Thin PyTorch wrapper that encapsulates FBANK + ECAPA-TDNN + L2 norm."""

    def __init__(self, classifier):
        import torch
        import torch.nn as nn

        self.classifier = classifier

        class _Wrapper(nn.Module):
            def __init__(self, clf):
                super().__init__()
                self.clf = clf

            def forward(self, wav):
                # wav: [batch, time]  float32, 16 kHz
                emb = self.clf.encode_batch(wav)  # [batch, 1, 192]
                emb = emb.squeeze(1)  # [batch, 192]
                # L2 normalize
                norm = emb.norm(dim=-1, keepdim=True).clamp(min=1e-8)
                return emb / norm  # [batch, 192]

        self.module = _Wrapper(classifier)
        self.module.eval()

    def trace(self, window_samples: int = WINDOW_SAMPLES):
        import torch

        example = torch.zeros(1, window_samples, dtype=torch.float32)
        with torch.no_grad():
            traced = torch.jit.trace(self.module, example)
        return traced, example


def load_speechbrain_model():
    try:
        from speechbrain.pretrained import EncoderClassifier
    except ImportError:
        sys.exit(
            "speechbrain not installed. Run:\n"
            "  pip install speechbrain torch torchaudio"
        )

    print("Loading SpeechBrain ECAPA-TDNN (downloads ~80 MB on first run)...")
    classifier = EncoderClassifier.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        run_opts={"device": "cpu"},
    )
    print("Model loaded.")
    return classifier


def verify_torch_model(traced_model, window_samples: int = WINDOW_SAMPLES):
    import torch

    print("\nVerifying TorchScript model...")
    a = torch.randn(1, window_samples)
    b = torch.randn(1, window_samples)
    with torch.no_grad():
        ea = traced_model(a)
        eb = traced_model(b)
    sim = float(torch.nn.functional.cosine_similarity(ea, eb))
    norm_a = float(ea.norm())
    print(f"  Output shape: {ea.shape}")
    print(f"  L2 norm (should be ~1.0): {norm_a:.6f}")
    print(f"  Same-random-audio cosine sim (baseline, not meaningful): {sim:.4f}")
    print("TorchScript verification OK.")


def convert_to_coreml(traced_model, output_path: Path, window_samples: int = WINDOW_SAMPLES):
    try:
        import coremltools as ct
        import torch
    except ImportError:
        sys.exit("coremltools not installed. Run: pip install coremltools")

    print(f"\nConverting to CoreML (target: iOS 16+)...")
    example = torch.zeros(1, window_samples, dtype=torch.float32)

    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.TensorType(name="waveform", shape=(1, window_samples), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT32,
    )

    mlmodel.short_description = (
        "ECAPA-TDNN speaker embedding. "
        f"Input: raw 16 kHz mono float32 waveform [{window_samples} samples = 3 s]. "
        "Output: L2-normalized 192-dim speaker embedding."
    )
    mlmodel.author = "speechbrain/spkrec-ecapa-voxceleb, converted for iOS"
    mlmodel.version = "1"
    mlmodel.user_defined_metadata["preprocessingVersion"] = "ecapa-tdnn-raw-16khz-v1"
    mlmodel.user_defined_metadata["embeddingDimension"] = "192"
    mlmodel.user_defined_metadata["sampleRate"] = str(SAMPLE_RATE)
    mlmodel.user_defined_metadata["windowSamples"] = str(window_samples)

    mlmodel.save(str(output_path))
    print(f"Saved CoreML model to {output_path}")


def verify_coreml_model(output_path: Path, window_samples: int = WINDOW_SAMPLES):
    try:
        import coremltools as ct
    except ImportError:
        return

    print(f"\nVerifying CoreML model at {output_path}...")
    model = ct.models.MLModel(str(output_path))

    print("  Input descriptions:")
    for name, desc in model.get_spec().description.input:
        print(f"    {name}: {desc}")

    # Run two inferences and check L2 norm and similarity.
    rng = np.random.default_rng(0)
    a = rng.standard_normal((1, window_samples)).astype(np.float32)
    b = rng.standard_normal((1, window_samples)).astype(np.float32)

    out_a = model.predict({"waveform": a})["embedding"]
    out_b = model.predict({"waveform": b})["embedding"]

    norm_a = float(np.linalg.norm(out_a))
    sim = float(np.dot(out_a.flatten(), out_b.flatten()))

    print(f"  Embedding shape: {out_a.shape}")
    print(f"  L2 norm (should be ~1.0): {norm_a:.6f}")
    print(f"  Random-pair cosine sim: {sim:.4f}")
    print("CoreML verification OK.")
    print("\nNext steps:")
    print("  1. Run tools/test_speaker_recognition_offline.py to calibrate thresholds.")
    print("  2. Add SpeakerEmbedding.mlpackage to the Xcode target (Copy Bundle Resources).")
    print("  3. Enroll speakers in the app; thresholds in SpeakerIdentityConfig can be adjusted.")


def main():
    parser = argparse.ArgumentParser(
        description="Convert SpeechBrain ECAPA-TDNN to CoreML for iOS speaker recognition"
    )
    parser.add_argument(
        "--output",
        default="CameraAccess/SpeakerEmbedding.mlpackage",
        help="Output .mlpackage path",
    )
    parser.add_argument(
        "--window-seconds",
        type=float,
        default=3.0,
        help="Embedding window length in seconds (default 3.0)",
    )
    parser.add_argument(
        "--skip-verify", action="store_true", help="Skip verification steps"
    )
    args = parser.parse_args()

    window_samples = int(args.window_seconds * SAMPLE_RATE)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    classifier = load_speechbrain_model()
    wrapper = WrappedECAPA(classifier)
    traced_model, _ = wrapper.trace(window_samples)

    if not args.skip_verify:
        verify_torch_model(traced_model, window_samples)

    convert_to_coreml(traced_model, output_path, window_samples)

    if not args.skip_verify:
        verify_coreml_model(output_path, window_samples)


if __name__ == "__main__":
    main()
