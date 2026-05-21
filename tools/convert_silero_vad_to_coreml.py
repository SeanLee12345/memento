#!/usr/bin/env python3
"""
Convert Silero VAD to a CoreML model for on-device voice activity detection.

The exported model accepts one chunk of mono 16 kHz audio samples (512 samples = 32 ms)
plus explicit LSTM state arrays, and returns a speech probability scalar plus the updated
LSTM state.  Passing explicit state instead of relying on CoreML's built-in state
mechanism keeps the conversion straightforward and avoids Core ML stateful-model
complexity on older iOS targets.

Usage:
  python tools/convert_silero_vad_to_coreml.py \
    --output CameraAccess/SileroVAD.mlpackage

Requirements:
  pip install torch coremltools onnx onnxruntime numpy
"""

import argparse
import sys
import tempfile
from pathlib import Path

import numpy as np


def load_silero_vad():
    """Download Silero VAD from torch.hub and return (model, onnx_path)."""
    try:
        import torch
    except ImportError:
        sys.exit("PyTorch not installed. Run: pip install torch")

    print("Loading Silero VAD via torch.hub (downloads ~1.5 MB on first run)...")
    model, utils = torch.hub.load(
        repo_or_dir="snakers4/silero-vad",
        model="silero_vad",
        force_reload=False,
        onnx=True,
    )
    print("Silero VAD loaded.")
    return model, utils


def export_to_onnx(output_dir: Path) -> Path:
    """Export Silero VAD to ONNX with explicit LSTM state I/O."""
    try:
        import torch
    except ImportError:
        sys.exit("PyTorch not installed.")

    model, _ = load_silero_vad()

    # Silero VAD ONNX is distributed directly — fetch the pre-built ONNX file.
    import urllib.request

    onnx_url = (
        "https://raw.githubusercontent.com/snakers4/silero-vad/master/"
        "files/silero_vad.onnx"
    )
    onnx_path = output_dir / "silero_vad.onnx"
    print(f"Downloading Silero VAD ONNX model to {onnx_path}...")
    urllib.request.urlretrieve(onnx_url, onnx_path)
    print("ONNX download complete.")
    return onnx_path


def verify_onnx(onnx_path: Path):
    try:
        import onnxruntime as ort
    except ImportError:
        print("onnxruntime not installed — skipping ONNX verification.")
        return

    sess = ort.InferenceSession(str(onnx_path))
    inputs = {i.name: i for i in sess.get_inputs()}
    outputs = {o.name: o for o in sess.get_outputs()}
    print("\nONNX model inputs:")
    for name, desc in inputs.items():
        print(f"  {name}: shape={desc.shape} type={desc.type}")
    print("ONNX model outputs:")
    for name, desc in outputs.items():
        print(f"  {name}: shape={desc.shape} type={desc.type}")

    # Run a dummy inference.
    chunk = np.zeros((1, 512), dtype=np.float32)
    sr = np.array(16_000, dtype=np.int64)
    h = np.zeros((2, 1, 64), dtype=np.float32)
    c = np.zeros((2, 1, 64), dtype=np.float32)
    feed = {"input": chunk, "sr": sr, "h": h, "c": c}
    result = sess.run(None, feed)
    print(f"\nDummy inference output (speech prob): {result[0]}")
    print("ONNX verification OK.")


def convert_to_coreml(onnx_path: Path, output_path: Path):
    try:
        import coremltools as ct
    except ImportError:
        sys.exit("coremltools not installed. Run: pip install coremltools")

    print(f"\nConverting {onnx_path.name} to CoreML...")
    model = ct.converters.onnx.convert(
        model=str(onnx_path),
        minimum_ios_deployment_target="16",
        # Map inputs explicitly so CoreML knows the shapes.
        inputs=[
            ct.TensorType(name="input", shape=(1, 512), dtype=np.float32),
            ct.TensorType(name="sr", shape=(), dtype=np.int64),
            ct.TensorType(name="h", shape=(2, 1, 64), dtype=np.float32),
            ct.TensorType(name="c", shape=(2, 1, 64), dtype=np.float32),
        ],
    )

    model.short_description = (
        "Silero VAD: voice activity detection. "
        "Input: 512 mono 16 kHz float32 audio samples + LSTM state. "
        "Output: speech probability + updated LSTM state."
    )
    model.author = "snakers4/silero-vad, converted for iOS"
    model.version = "5"

    model.save(str(output_path))
    print(f"Saved CoreML model to {output_path}")
    print("\nUsage in iOS:")
    print("  1. Add SileroVAD.mlpackage to the Xcode target (Copy Bundle Resources).")
    print("  2. Update VoiceActivityDetector.swift to load and run this model.")
    print("  3. Pass 512-sample chunks at 16 kHz; carry h/c state between chunks.")


def main():
    parser = argparse.ArgumentParser(description="Convert Silero VAD to CoreML")
    parser.add_argument(
        "--output",
        default="CameraAccess/SileroVAD.mlpackage",
        help="Output .mlpackage path",
    )
    parser.add_argument(
        "--skip-verify", action="store_true", help="Skip ONNX runtime verification"
    )
    args = parser.parse_args()

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        onnx_path = export_to_onnx(Path(tmp))
        if not args.skip_verify:
            verify_onnx(onnx_path)
        convert_to_coreml(onnx_path, output_path)


if __name__ == "__main__":
    main()
