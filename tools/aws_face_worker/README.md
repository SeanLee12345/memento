# AWS Face Embedding Worker

This worker exposes AdaFace IR-101 (WebFace12M) embeddings for the iOS app. It
shares EC2 instance `i-0c400af918e775f20` (`m7i-flex.large`, us-west-1) with the
speaker worker — face runs on port `8080`, speaker on port `8090`. For GPU
inference move the worker to a `g4dn.xlarge` instance unchanged; the iOS side
discovers the public IP via the same `DiarizenStartEC2` Lambda regardless.

The iOS app contract:

```text
GET  /health
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

The iOS app does not need an endpoint override when the AWS AdaFace toggle is
on; the `DiarizenStartEC2` Lambda starts the EC2 instance via `startLiveFace`
and the app probes the returned public IP at `:8080/health`. For manual testing
without the Lambda, set the endpoint override to:

```text
http://<ec2-public-dns-or-private-ip>:8080
```

The security group `sg-0578a4db814b95156` already permits inbound TCP `8080`
from the development network. For production, put the worker behind TLS and
restrict the source CIDR further.

## Model

The service loads the real AdaFace IR-101 WebFace12M model from Hugging Face:

```text
minchul/cvlface_adaface_ir101_webface12m
```

Input crops are resized to `112x112`, converted to RGB, normalized with `(pixel / 255 - 0.5) / 0.5`,
and returned as L2-normalized embeddings for app-side matching.
