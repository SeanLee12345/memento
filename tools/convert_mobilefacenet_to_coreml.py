#!/usr/bin/env python3
"""Convert Xiaoccer/MobileFaceNet_Pytorch checkpoint to Core ML.

Source repository:
https://github.com/Xiaoccer/MobileFaceNet_Pytorch

The upstream checkpoint in that repository was trained on aligned
`112x96` RGB face images. The converted Core ML model therefore expects an
NCHW Float32 tensor named `face` with shape `[1, 3, 112, 96]`.

MetaFace preprocessing must:

1. Detect face with Vision.
2. Crop/pad/align the face.
3. Resize the crop to width=96, height=112.
4. Normalize RGB channels as `(pixel - 127.5) / 128.0`.
5. Run MobileFaceNet.
6. L2 normalize the output embedding before storage or comparison.
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import shutil
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo",
        required=True,
        help="Path to a clone of https://github.com/Xiaoccer/MobileFaceNet_Pytorch",
    )
    parser.add_argument(
        "--checkpoint",
        default=None,
        help="Path to Xiaoccer checkpoint. Defaults to <repo>/model/best/068.ckpt.",
    )
    parser.add_argument("--output", default="CameraAccess/MobileFaceNet.mlpackage")
    parser.add_argument("--ios-target", default="iOS17")
    return parser.parse_args()


def load_mobilefacenet_class(repo_path: pathlib.Path):
    model_path = repo_path / "core" / "model.py"
    if not model_path.exists():
        raise SystemExit(f"Xiaoccer model.py not found: {model_path}")

    spec = importlib.util.spec_from_file_location("xiaoccer_mobilefacenet_model", model_path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"Could not import model module from {model_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.MobileFacenet


def main() -> int:
    args = parse_args()
    repo_path = pathlib.Path(args.repo).expanduser().resolve()
    checkpoint_path = pathlib.Path(args.checkpoint).expanduser().resolve() if args.checkpoint else repo_path / "model" / "best" / "068.ckpt"
    output_path = pathlib.Path(args.output).expanduser().resolve()

    if not repo_path.exists():
      raise SystemExit(f"Xiaoccer repository not found: {repo_path}")
    if not checkpoint_path.exists():
      raise SystemExit(f"Xiaoccer checkpoint not found: {checkpoint_path}")

    import coremltools as ct
    import numpy as np
    import torch

    MobileFacenet = load_mobilefacenet_class(repo_path)
    model = MobileFacenet().eval()
    checkpoint = torch.load(str(checkpoint_path), map_location="cpu")
    state_dict = checkpoint["net_state_dict"] if isinstance(checkpoint, dict) and "net_state_dict" in checkpoint else checkpoint
    model.load_state_dict(state_dict)

    example = torch.randn(1, 3, 112, 96)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
        traced = torch.jit.freeze(traced.eval())
        output = traced(example)

    if output.ndim != 2 or output.shape[-1] <= 0:
        raise SystemExit(f"Unexpected MobileFaceNet output shape: {tuple(output.shape)}")

    target = getattr(ct.target, args.ios_target)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="face", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=target,
    )
    mlmodel.author = "Xiaoccer/MobileFaceNet_Pytorch converted for MetaFace"
    mlmodel.license = "Verify Xiaoccer/MobileFaceNet_Pytorch code, checkpoint, and dataset license suitability before production use"
    mlmodel.short_description = "MobileFaceNet face embedding model converted from Xiaoccer/MobileFaceNet_Pytorch"
    mlmodel.version = f"xiaoccer-epoch-{checkpoint.get('epoch', 'unknown')}" if isinstance(checkpoint, dict) else "xiaoccer-checkpoint"
    mlmodel.user_defined_metadata["source_repository"] = "https://github.com/Xiaoccer/MobileFaceNet_Pytorch"
    mlmodel.user_defined_metadata["source_checkpoint"] = str(checkpoint_path)
    mlmodel.user_defined_metadata["xiaoccer_checkpoint"] = mlmodel.version
    mlmodel.user_defined_metadata["preprocessing"] = "Resize RGB face crop to 96x112, normalize as (pixel - 127.5) / 128.0, NCHW"
    mlmodel.user_defined_metadata["preprocessing_version"] = "xiaoccer-mobilefacenet-rgb-minus-127p5-div-128-v1"
    mlmodel.user_defined_metadata["input_shape"] = "1x3x112x96"
    mlmodel.user_defined_metadata["embedding_dimension"] = str(output.shape[-1])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        if output_path.is_dir():
            shutil.rmtree(output_path)
        else:
            output_path.unlink()
    mlmodel.save(str(output_path))
    print(f"Saved {output_path}")
    print("Source repository: https://github.com/Xiaoccer/MobileFaceNet_Pytorch")
    print(f"Checkpoint: {checkpoint_path}")
    print("Input shape: 1x3x112x96")
    print(f"Embedding dimension: {output.shape[-1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
