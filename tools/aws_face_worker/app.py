import base64
import hashlib
import hmac
import io
import json
import os
import shutil
import sys
import time
from typing import List, Optional

import numpy as np
import torch
from fastapi import FastAPI, Header, HTTPException
from huggingface_hub import hf_hub_download
from pydantic import BaseModel, Field
from PIL import Image
from transformers import AutoModel


MODEL_NAME = "AdaFace"
MODEL_VERSION = "cvlface_adaface_ir101_webface12m"
MODEL_SOURCE = "minchul/cvlface_adaface_ir101_webface12m"
PREPROCESSING_VERSION = "adaface-ir101-112-rgb-normalize-0p5-v1"
MODEL_CACHE_PATH = os.path.expanduser("~/.cvlface_cache/minchul/cvlface_adaface_ir101_webface12m")

app = FastAPI(title="MetaFace AWS GPU Face Worker")


class FaceEmbedRequest(BaseModel):
    image_base64: str = Field(min_length=1)
    image_format: Optional[str] = "jpeg"


class FaceEmbedResponse(BaseModel):
    embedding: List[float]
    model_name: str
    model_version: str
    model_source: str
    preprocessing_version: str


device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
model = None


@app.on_event("startup")
def load_model() -> None:
    global model
    hf_token = os.environ.get("HF_TOKEN")
    model_path = download_model_repo(MODEL_SOURCE, MODEL_CACHE_PATH, hf_token)
    cwd = os.getcwd()
    os.chdir(model_path)
    sys.path.insert(0, model_path)
    try:
        model = AutoModel.from_pretrained(
            model_path,
            trust_remote_code=True,
            token=hf_token,
        ).eval().to(device)
    finally:
        os.chdir(cwd)
        sys.path.pop(0)


@app.get("/health")
def health(authorization: Optional[str] = Header(default=None)) -> dict:
    require_authorization(authorization)
    return {
        "status": "ok",
        "device": str(device),
        "cuda": torch.cuda.is_available(),
        "model_name": MODEL_NAME,
        "model_version": MODEL_VERSION,
        "model_source": MODEL_SOURCE,
        "runtime_model": MODEL_SOURCE,
    }


@app.post("/face/embed", response_model=FaceEmbedResponse)
def embed_face(payload: FaceEmbedRequest, authorization: Optional[str] = Header(default=None)) -> FaceEmbedResponse:
    require_authorization(authorization)

    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    try:
      raw = base64.b64decode(payload.image_base64)
      image = Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception as exc:
      raise HTTPException(status_code=400, detail=f"Invalid image: {exc}") from exc

    tensor = preprocess(image).to(device)
    with torch.inference_mode():
        vector = model(tensor).detach().cpu().numpy()[0].astype(np.float32)
    norm = float(np.linalg.norm(vector))
    if not np.isfinite(norm) or norm <= 1e-6:
        raise HTTPException(status_code=500, detail="Invalid embedding norm")
    vector = vector / norm

    return FaceEmbedResponse(
        embedding=vector.tolist(),
        model_name=MODEL_NAME,
        model_version=MODEL_VERSION,
        model_source=MODEL_SOURCE,
        preprocessing_version=PREPROCESSING_VERSION,
    )


def require_authorization(authorization: Optional[str]) -> None:
    if validate_worker_session_token(authorization, expected_worker="face"):
        return
    expected_key = os.environ.get("FACE_WORKER_API_KEY", "").strip()
    if expected_key and authorization != f"Bearer {expected_key}":
        raise HTTPException(status_code=401, detail="Unauthorized")


def validate_worker_session_token(authorization: Optional[str], expected_worker: str) -> bool:
    secret = os.environ.get("WORKER_TOKEN_SIGNING_SECRET", "").strip()
    if not secret or not authorization or not authorization.startswith("Bearer "):
        return False
    token = authorization.removeprefix("Bearer ").strip()
    parts = token.split(".")
    if len(parts) != 3:
        return False
    signing_input = f"{parts[0]}.{parts[1]}".encode("utf-8")
    expected_signature = hmac.new(secret.encode("utf-8"), signing_input, hashlib.sha256).digest()
    if not hmac.compare_digest(base64url_encode(expected_signature), parts[2]):
        return False
    try:
        payload = json.loads(base64url_decode(parts[1]).decode("utf-8"))
    except Exception:
        return False
    now = int(time.time())
    return (
        payload.get("aud") == "memento-worker"
        and payload.get("worker") == expected_worker
        and isinstance(payload.get("exp"), int)
        and payload["exp"] >= now
    )


def base64url_decode(value: str) -> bytes:
    padded = value + "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(padded.encode("utf-8"))


def base64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("utf-8").rstrip("=")


def preprocess(image: Image.Image) -> torch.Tensor:
    resized = image.resize((112, 112), Image.BILINEAR)
    arr = np.asarray(resized).astype(np.float32)
    arr = (arr / 255.0 - 0.5) / 0.5
    arr = np.transpose(arr, (2, 0, 1))
    return torch.from_numpy(arr).unsqueeze(0)


def download_model_repo(repo_id: str, path: str, token: Optional[str]) -> str:
    force_download = os.environ.get("FORCE_FACE_MODEL_DOWNLOAD", "").lower() in {"1", "true", "yes"}
    if force_download and os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(path, exist_ok=True)
    files_path = os.path.join(path, "files.txt")
    if not os.path.exists(files_path):
        hf_hub_download(repo_id, "files.txt", token=token, local_dir=path, local_dir_use_symlinks=False)
    with open(files_path, "r", encoding="utf-8") as handle:
        files = [line.strip() for line in handle.read().splitlines() if line.strip()]
    for filename in files + ["config.json", "wrapper.py", "model.safetensors"]:
        target = os.path.join(path, filename)
        if not os.path.exists(target):
            hf_hub_download(repo_id, filename, token=token, local_dir=path, local_dir_use_symlinks=False)
    return path
