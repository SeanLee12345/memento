# AWS g4dn.xlarge Face Embedding Worker

This worker is intended for an AWS `g4dn.xlarge` GPU instance running Ubuntu with NVIDIA drivers. It exposes the iOS app contract:

```text
POST /face/embed
Authorization: Bearer <FACE_WORKER_API_KEY>
Content-Type: application/json
```

Request:

```json
{
  "image_base64": "...",
  "image_format": "jpeg"
}
```

Response:

```json
{
  "embedding": [0.01, -0.02],
  "model_name": "AdaFace",
  "model_version": "cvlface_adaface_ir101_webface12m",
  "model_source": "minchul/cvlface_adaface_ir101_webface12m",
  "preprocessing_version": "adaface-ir101-112-rgb-normalize-0p5-v1"
}
```

## AWS Instance

Use:

```text
g4dn.xlarge
1x NVIDIA T4 16GB
4 vCPU
16GB RAM
```

This is enough for AdaFace inference. Use Spot when possible; stop the instance when not testing.

The AWS account must have GPU capacity quota for `g4dn.xlarge`. If `run-instances` returns
`VcpuLimitExceeded` for the GPU instance bucket, request an EC2 quota increase for G-family
on-demand GPU instances before launching this worker. If Spot returns `MaxSpotInstanceCountExceeded`,
use on-demand temporarily or request a Spot quota increase.

## Run

```sh
cd tools/aws_face_worker
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
export FACE_WORKER_API_KEY='replace-me'
uvicorn app:app --host 0.0.0.0 --port 8080
```

For CPU-only testing on a small EC2 instance such as `m7i-flex.large`, avoid the
default CUDA PyTorch wheel set:

```sh
pip install -r requirements-cpu.txt
pip install --index-url https://download.pytorch.org/whl/cpu \
  torch==2.5.1+cpu torchvision==0.20.1+cpu
```

CPU inference is expected to be much slower than the `g4dn.xlarge` GPU path, but
it is usable for occasional refinement or post-session processing.

Then set the iOS app's `AWS AdaFace embeddings` endpoint to:

```text
http://<ec2-public-dns-or-private-ip>:8080
```

For production, put the worker behind TLS and restrict inbound security group access.

## Model

The service loads the real AdaFace IR-101 WebFace12M model from Hugging Face:

```text
minchul/cvlface_adaface_ir101_webface12m
```

Input crops are resized to `112x112`, converted to RGB, normalized with `(pixel / 255 - 0.5) / 0.5`,
and returned as L2-normalized embeddings for app-side matching.
