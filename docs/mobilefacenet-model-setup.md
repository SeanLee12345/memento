# MobileFaceNet Model Setup

MetaFace uses MobileFaceNet as the preferred Core ML face embedding model for live on-device recognition.

This repo currently includes `CameraAccess/MobileFaceNet.mlpackage`, which should be converted from:

```text
https://github.com/Xiaoccer/MobileFaceNet_Pytorch
```

The upstream PyTorch implementation includes the MobileFaceNet architecture and a trained checkpoint at `model/best/068.ckpt`. It reports LFW accuracy from aligned 112x96 images, but this still needs calibration on Ray-Ban Meta glasses frames before relying on any identity threshold.

Expected resource priority:

1. `MobileFaceNet.mlpackage`
2. `MobileFaceNet.mlmodel`
3. `MobileFaceNet.mlmodelc`

`FaceNet` and `FaceEmbedding` names are checked only as explicit fallback resources for older local builds. They are not preferred.

## Xcode target membership

1. Add `MobileFaceNet.mlpackage` or `MobileFaceNet.mlmodel` to the Xcode Project Navigator.
2. Select the model file.
3. Open File Inspector with `Option-Command-1`.
4. Check Target Membership for the `CameraAccess` app target.
5. Open `CameraAccess > Build Phases`.
6. Confirm the model appears in Copy Bundle Resources.

## Runtime checks

At startup the app logs:

```text
[FACE_EMBEDDING_MODEL] modelLoaded=...
[FACE_EMBEDDING_MODEL] loaded name=MobileFaceNet source=Xiaoccer/MobileFaceNet_Pytorch ...
```

For a loaded model, the app reads the actual input and output metadata from `MLModel.modelDescription`. It defaults to `96x112` only when the model does not declare an input size. The embedding dimension is read from the output `MLMultiArray` shape and is not hardcoded.

For multi-array models, the active preprocessing path is:

```text
RGB face crop resized to width=96 height=112, then channel values normalized as (pixel - 127.5) / 128.0
```

The Xiaoccer checkpoint is trained for aligned `112x96` inputs, not square `112x112` inputs. The app reads the Core ML input shape and uses the declared width and height. If your MobileFaceNet conversion expects different dimensions or normalization, update the preprocessing mode before collecting enrollment embeddings.

## Regenerate the model

```sh
python -m venv /tmp/metaface-mobilefacenet-venv
/tmp/metaface-mobilefacenet-venv/bin/python -m pip install torch coremltools numpy
git clone https://github.com/Xiaoccer/MobileFaceNet_Pytorch.git /tmp/MobileFaceNet_Pytorch
/tmp/metaface-mobilefacenet-venv/bin/python tools/convert_mobilefacenet_to_coreml.py \
  --repo /tmp/MobileFaceNet_Pytorch \
  --checkpoint /tmp/MobileFaceNet_Pytorch/model/best/068.ckpt \
  --output CameraAccess/MobileFaceNet.mlpackage
```

After regeneration, add or keep `CameraAccess/MobileFaceNet.mlpackage` in the `CameraAccess` target and rebuild. Existing embeddings from a different MobileFaceNet source or preprocessing version are intentionally treated as incompatible and skipped during matching.
