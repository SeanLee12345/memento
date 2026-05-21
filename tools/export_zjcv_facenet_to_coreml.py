#!/usr/bin/env python3
"""Export a trained ZJCV/facenet checkpoint to a Core ML FaceNet.mlpackage.

This script requires a real trained checkpoint from https://github.com/ZJCV/facenet.
It does not download or fabricate weights.
"""

from __future__ import annotations

import argparse
import pathlib
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--facenet-repo", required=True, help="Path to a clone of https://github.com/ZJCV/facenet")
    parser.add_argument("--checkpoint", required=True, help="Path to a trained ZJCV/facenet .pth checkpoint")
    parser.add_argument("--arch", default="resnet18", help="ZJCV/facenet recognizer arch, e.g. resnet18")
    parser.add_argument("--embedding-dim", type=int, default=128, help="MODEL.HEAD.NUM_CLASSES from the training config")
    parser.add_argument("--image-size", type=int, default=224, help="Input image size from the training config")
    parser.add_argument("--output", default="CameraAccess/FaceNet.mlpackage", help="Output Core ML package path")
    parser.add_argument("--output-key", default="output", help="ZJCV/zcls KEY_OUTPUT value used by the model dict")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = pathlib.Path(args.facenet_repo).expanduser().resolve()
    checkpoint_path = pathlib.Path(args.checkpoint).expanduser().resolve()
    output_path = pathlib.Path(args.output).expanduser().resolve()

    if not repo.exists():
        raise SystemExit(f"ZJCV/facenet repo not found: {repo}")
    if not checkpoint_path.exists():
        raise SystemExit(f"Checkpoint not found: {checkpoint_path}")

    sys.path.insert(0, str(repo))

    try:
        import coremltools as ct
        import numpy as np
        import torch
        import torch.nn as nn
        from similarity.model.resnet.build import get_resnet
    except ImportError as exc:
        raise SystemExit(
            "Missing conversion dependency. Install ZJCV/facenet requirements plus coremltools and torch first."
        ) from exc

    class FaceNetOutputWrapper(nn.Module):
        def __init__(self, backbone: nn.Module, output_key: str):
            super().__init__()
            self.backbone = backbone
            self.output_key = output_key

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            outputs = self.backbone(x)
            return outputs[self.output_key]

    model = get_resnet(num_classes=args.embedding_dim, arch=args.arch)
    checkpoint = torch.load(str(checkpoint_path), map_location="cpu")
    state_dict = checkpoint.get("model", checkpoint)
    model.load_state_dict(state_dict)
    model.eval()

    wrapped = FaceNetOutputWrapper(model, args.output_key).eval()
    example = torch.randn(1, 3, args.image_size, args.image_size)
    traced = torch.jit.trace(wrapped, example)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name="face",
                shape=example.shape,
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
    )
    mlmodel.author = "Converted from ZJCV/facenet"
    mlmodel.license = "Apache-2.0 source; checkpoint license depends on training data and weights"
    mlmodel.short_description = "FaceNet embedding model converted from https://github.com/ZJCV/facenet"
    mlmodel.version = f"zjcv-facenet-{args.arch}-dim{args.embedding_dim}"
    mlmodel.user_defined_metadata["source_repository"] = "https://github.com/ZJCV/facenet"
    mlmodel.user_defined_metadata["zjcv_facenet_arch"] = args.arch
    mlmodel.user_defined_metadata["zjcv_facenet_checkpoint"] = checkpoint_path.name
    mlmodel.user_defined_metadata["preprocessing"] = "Resize 224x224, RGB, (pixel/255 - 0.445) / 0.225"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))
    print(f"Saved Core ML model to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
