# Inactive ZJCV/facenet Core ML Conversion Notes

MetaFace now prefers MobileFaceNet for the active on-device identity path. This document is retained only as inactive reference material for an explicit FaceNet fallback experiment. It is not the default recognition path.

Historical FaceNet source:

https://github.com/ZJCV/facenet

That repository is a PyTorch training implementation. It does not publish an iOS-ready `.mlmodel`, `.mlpackage`, `.mlmodelc`, ONNX file, or pretrained checkpoint in the repository. A trained checkpoint is required before MetaFace can produce real identity embeddings.

## ZJCV/facenet facts used by the app

- Architecture is built in `similarity/model/resnet/build.py`.
- The LFW config uses `resnet18` with `MODEL.HEAD.NUM_CLASSES: 128`, so the expected embedding dimension for that config is `128`.
- The LFW config resizes inputs to `224x224`.
- The LFW config normalizes RGB channels with mean `(0.445, 0.445, 0.445)`, std `(0.225, 0.225, 0.225)`, and pixel scale `255.0`.
- Checkpoints are saved as `.pth` files containing a `model` state dict.

## Conversion path

1. Clone and train or obtain a ZJCV/facenet checkpoint.

   ```sh
   git clone https://github.com/ZJCV/facenet.git /tmp/zjcv-facenet
   cd /tmp/zjcv-facenet
   pip install -r requirements.txt
   CUDA_VISIBLE_DEVICES=0 python tools/train.py -cfg=configs/lfw/r18_lfw_224_e2_adam_g1.yaml
   ```

2. Convert the trained checkpoint to Core ML from this app repo.

   ```sh
   python tools/export_zjcv_facenet_to_coreml.py \
     --facenet-repo /tmp/zjcv-facenet \
     --checkpoint /tmp/zjcv-facenet/outputs/lfw/r18_lfw_224_e2_adam_g1/model_000001.pth \
     --arch resnet18 \
     --embedding-dim 128 \
     --image-size 224 \
     --output CameraAccess/FaceNet.mlpackage
   ```

3. Add `CameraAccess/FaceNet.mlpackage` to Xcode.

   - Drag `FaceNet.mlpackage` into the Project Navigator.
   - Select the file and open File Inspector with `Option-Command-1`.
   - Enable Target Membership for the `CameraAccess` app target.
   - Open `CameraAccess > Build Phases`.
   - Confirm the model appears in Copy Bundle Resources.

4. Build and run on device.

Expected startup logs:

```text
[FACE_EMBEDDING_MODEL] loaded name=FaceNet source=ZJCV/facenet ...
[FACE_EMBEDDING] FaceNet/Core ML model loaded modelName=FaceNet ... embeddingDimension=128 inputImageSize=224x224 preprocessing=zjcvFacenetRGB224MeanStd
```

If this fallback model is absent, MetaFace remains in detection-only mode unless the preferred MobileFaceNet model is bundled. The app must not claim identity recognition is enabled without an active embedding model.
