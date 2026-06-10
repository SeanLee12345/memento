import base64
import hashlib
import hmac
import io
import json
import os
import time
from typing import List, Optional

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from nemo.collections.asr.models import EncDecSpeakerLabelModel
from pydantic import BaseModel


MODEL_NAME = "SpeakerEmbedding"
MODEL_VERSION = "nvidia-speakerverification-en-titanet-large-v1"
MODEL_SOURCE = "nvidia/speakerverification_en_titanet_large"
PREPROCESSING_VERSION = "titanet-raw-16khz-v1"
SAMPLE_RATE = 16_000
WINDOW_SAMPLES = 48_000

app = FastAPI(title="MetaFace AWS Speaker Embedding Worker")
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
model: Optional[EncDecSpeakerLabelModel] = None


class SpeakerEmbedResponse(BaseModel):
    model: str
    model_name: str
    model_version: str
    model_source: str
    preprocessing_version: str
    dimension: int
    normalized: bool
    embedding: List[float]


@app.on_event("startup")
def load_model() -> None:
    global model
    model = EncDecSpeakerLabelModel.from_pretrained(MODEL_SOURCE)
    model.eval().to(device)


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
    }


@app.post("/speaker/embed", response_model=SpeakerEmbedResponse)
async def embed_speaker(
    file: UploadFile = File(...),
    authorization: Optional[str] = Header(default=None),
) -> SpeakerEmbedResponse:
    require_authorization(authorization)
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    raw = await file.read()
    try:
        samples, sample_rate = sf.read(io.BytesIO(raw), dtype="float32")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Invalid WAV: {exc}") from exc

    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    if sample_rate != SAMPLE_RATE:
        samples = resample_linear(samples, sample_rate, SAMPLE_RATE)
    samples = pad_or_trim(samples.astype(np.float32), WINDOW_SAMPLES)

    waveform = torch.from_numpy(samples).unsqueeze(0).to(device)
    lengths = torch.full((1,), WINDOW_SAMPLES, dtype=torch.int64, device=device)
    with torch.inference_mode():
        _, embedding = model(input_signal=waveform, input_signal_length=lengths)
        vector = embedding.detach().cpu().numpy()[0].astype(np.float32)
    norm = float(np.linalg.norm(vector))
    if not np.isfinite(norm) or norm <= 1e-6:
        raise HTTPException(status_code=500, detail="Invalid embedding norm")
    vector = vector / norm

    return SpeakerEmbedResponse(
        model=MODEL_NAME,
        model_name=MODEL_NAME,
        model_version=MODEL_VERSION,
        model_source=MODEL_SOURCE,
        preprocessing_version=PREPROCESSING_VERSION,
        dimension=int(vector.shape[0]),
        normalized=True,
        embedding=vector.tolist(),
    )


def require_authorization(authorization: Optional[str]) -> None:
    if validate_worker_session_token(authorization, expected_worker="speaker"):
        return
    expected_key = os.environ.get("SPEAKER_WORKER_API_KEY", "").strip()
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


def pad_or_trim(samples: np.ndarray, count: int) -> np.ndarray:
    if samples.shape[0] >= count:
        return samples[:count]
    return np.pad(samples, (0, count - samples.shape[0]))


def resample_linear(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate <= 0:
        raise HTTPException(status_code=400, detail=f"Invalid sample rate {source_rate}")
    if samples.size == 0:
        return samples
    duration = samples.shape[0] / float(source_rate)
    target_count = max(1, int(round(duration * target_rate)))
    source_x = np.linspace(0.0, duration, num=samples.shape[0], endpoint=False)
    target_x = np.linspace(0.0, duration, num=target_count, endpoint=False)
    return np.interp(target_x, source_x, samples).astype(np.float32)
