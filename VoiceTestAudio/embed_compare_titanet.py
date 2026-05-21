#!/usr/bin/env python3
"""Compare speaker embeddings with NVIDIA NeMo TitaNet.

This is an offline diagnostic helper for local MOV/WAV tests. It does not
change the iOS app or its bundled Core ML model.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from nemo.collections.asr.models import EncDecSpeakerLabelModel


MODEL_NAME = "nvidia/speakerverification_en_titanet_large"
SAMPLE_RATE = 16_000


@dataclass
class EmbeddingResult:
    label: str
    vector: np.ndarray
    duration: float
    windows: int


def l2_normalize(vector: np.ndarray) -> np.ndarray:
    vector = np.asarray(vector, dtype=np.float32).reshape(-1)
    norm = float(np.linalg.norm(vector))
    if not np.isfinite(norm) or norm <= 1e-8:
        raise ValueError(f"invalid embedding norm={norm}")
    return vector / norm


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(l2_normalize(a), l2_normalize(b)))


def read_audio(path: Path) -> tuple[np.ndarray, int]:
    audio, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if audio.ndim == 2:
        audio = np.mean(audio, axis=1)
    return audio.astype(np.float32), int(sr)


def save_temp_window(path: Path, audio: np.ndarray, sr: int, index: int) -> Path:
    out_dir = path.parent / ".titanet_windows"
    out_dir.mkdir(exist_ok=True)
    out = out_dir / f"{path.stem}_window_{index:03d}.wav"
    sf.write(str(out), audio, sr, subtype="PCM_16")
    return out


def embed_file(model: EncDecSpeakerLabelModel, path: Path) -> np.ndarray:
    with torch.inference_mode():
        embedding = model.get_embedding(str(path))
    if isinstance(embedding, torch.Tensor):
        embedding = embedding.detach().cpu().numpy()
    return l2_normalize(np.asarray(embedding, dtype=np.float32))


def embed_whole_file(model: EncDecSpeakerLabelModel, path: Path) -> EmbeddingResult:
    audio, sr = read_audio(path)
    if sr != SAMPLE_RATE:
        raise ValueError(f"{path} is {sr} Hz; expected {SAMPLE_RATE} Hz")
    return EmbeddingResult(
        label=path.name,
        vector=embed_file(model, path),
        duration=len(audio) / sr,
        windows=1,
    )


def embed_average_windows(
    model: EncDecSpeakerLabelModel,
    path: Path,
    window_seconds: float,
    hop_seconds: float,
) -> EmbeddingResult:
    audio, sr = read_audio(path)
    if sr != SAMPLE_RATE:
        raise ValueError(f"{path} is {sr} Hz; expected {SAMPLE_RATE} Hz")

    window_samples = int(round(window_seconds * sr))
    hop_samples = int(round(hop_seconds * sr))
    if len(audio) < window_samples:
        padded = np.zeros(window_samples, dtype=np.float32)
        padded[: len(audio)] = audio
        audio = padded

    embeddings: list[np.ndarray] = []
    index = 0
    for start in range(0, len(audio) - window_samples + 1, hop_samples):
        window = audio[start : start + window_samples]
        window_path = save_temp_window(path, window, sr, index)
        embeddings.append(embed_file(model, window_path))
        index += 1

    if not embeddings:
        raise ValueError(f"no windows produced for {path}")

    averaged = l2_normalize(np.mean(np.stack(embeddings), axis=0))
    return EmbeddingResult(
        label=f"{path.name} avg({window_seconds:.1f}s/{hop_seconds:.1f}s)",
        vector=averaged,
        duration=len(audio) / sr,
        windows=len(embeddings),
    )


def compare_pair(a: EmbeddingResult, b: EmbeddingResult) -> str:
    score = cosine(a.vector, b.vector)
    return (
        f"{a.label} vs {b.label}: cosine={score:.6f} "
        f"dim={a.vector.size} durations={a.duration:.2f}s/{b.duration:.2f}s "
        f"windows={a.windows}/{b.windows}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pairs", nargs="+", help="Even number of wav paths: a b [c d ...]")
    parser.add_argument("--window-seconds", type=float, default=0.0)
    parser.add_argument("--hop-seconds", type=float, default=1.0)
    args = parser.parse_args()

    if len(args.pairs) % 2 != 0:
        raise SystemExit("Pass an even number of files so they form pairs.")

    print(f"Loading {MODEL_NAME}")
    model = EncDecSpeakerLabelModel.from_pretrained(MODEL_NAME)
    model.eval()

    for left, right in zip(args.pairs[0::2], args.pairs[1::2]):
        left_path = Path(left)
        right_path = Path(right)
        if args.window_seconds > 0:
            left_embedding = embed_average_windows(model, left_path, args.window_seconds, args.hop_seconds)
            right_embedding = embed_average_windows(model, right_path, args.window_seconds, args.hop_seconds)
        else:
            left_embedding = embed_whole_file(model, left_path)
            right_embedding = embed_whole_file(model, right_path)
        print(compare_pair(left_embedding, right_embedding))


if __name__ == "__main__":
    main()
