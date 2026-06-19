#!/usr/bin/env python3
"""Run DiariZen or NVIDIA Sortformer and emit RTTM plus timing data."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


def write_rttm(path: Path, recording_id: str, segments: list[tuple[float, float, str]]) -> None:
    with path.open("w") as output:
        for start, end, speaker in segments:
            duration = max(0.0, end - start)
            if duration <= 0:
                continue
            output.write(
                f"SPEAKER {recording_id} 1 {start:.3f} {duration:.3f} <NA> <NA> {speaker} <NA> <NA>\n"
            )


def parse_sortformer_segment(segment: object) -> tuple[float, float, str]:
    if isinstance(segment, str):
        fields = segment.replace(",", " ").split()
    elif isinstance(segment, (tuple, list)):
        fields = list(segment)
    else:
        raise TypeError(f"Unsupported Sortformer segment: {segment!r}")
    if len(fields) < 3:
        raise ValueError(f"Incomplete Sortformer segment: {segment!r}")
    return float(fields[0]), float(fields[1]), str(fields[2])


def run_diarizen(model_id: str, audio_paths: list[Path], output_dir: Path) -> dict[str, object]:
    import torch

    sys.path.insert(0, "/opt/DiariZen/pyannote-audio")
    sys.path.insert(0, "/opt/DiariZen")
    from diarizen.pipelines.inference import DiariZenPipeline

    load_start = time.perf_counter()
    model = DiariZenPipeline.from_pretrained(repo_id=model_id)
    model.embedding_batch_size = 4
    model.segmentation_batch_size = 4
    load_seconds = time.perf_counter() - load_start
    model("/opt/DiariZen/example/EN2002a_30s.wav")

    files = []
    for audio_path in audio_paths:
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
        started = time.perf_counter()
        annotation = model(str(audio_path))
        elapsed = time.perf_counter() - started
        segments = sorted(
            (turn.start, turn.end, str(speaker))
            for turn, _, speaker in annotation.itertracks(yield_label=True)
        )
        write_rttm(output_dir / f"{audio_path.stem}.rttm", audio_path.stem, segments)
        files.append(
            {
                "id": audio_path.stem,
                "elapsed_seconds": elapsed,
                "speakers": len({speaker for _, _, speaker in segments}),
                "peak_gpu_memory_mib": torch.cuda.max_memory_allocated() / 1024 / 1024
                if torch.cuda.is_available()
                else 0.0,
            }
        )
    return {"model": model_id, "load_seconds": load_seconds, "files": files}


def run_sortformer(model_id: str, audio_paths: list[Path], output_dir: Path) -> dict[str, object]:
    import torch

    # NeMo 2.6 pulls NVIDIA One Logger during import. Its Lightning wrapper is
    # inference-irrelevant here, but can fail on strict signature checks against
    # newer Lightning releases.
    try:
        import overrides as overrides_package
        import overrides.overrides as overrides_module

        def override_without_checks(method=None, *, check_signature=True, check_at_runtime=False):
            if method is None:
                def decorator(decorated):
                    setattr(decorated, "__override__", True)
                    return decorated

                return decorator
            setattr(method, "__override__", True)
            return method

        overrides_package.override = override_without_checks
        overrides_module.override = override_without_checks
    except Exception:
        pass

    from nemo.collections.asr.models import SortformerEncLabelModel

    load_start = time.perf_counter()
    model = SortformerEncLabelModel.from_pretrained(model_id).eval().cuda()
    if "streaming" in model_id:
        model.sortformer_modules.chunk_len = 340
        model.sortformer_modules.chunk_right_context = 40
        model.sortformer_modules.fifo_len = 40
        model.sortformer_modules.spkcache_update_period = 300
    load_seconds = time.perf_counter() - load_start
    model.diarize(audio=["/opt/DiariZen/example/EN2002a_30s.wav"], batch_size=1)

    files = []
    for audio_path in audio_paths:
        torch.cuda.reset_peak_memory_stats()
        started = time.perf_counter()
        prediction = model.diarize(audio=[str(audio_path)], batch_size=1)[0]
        elapsed = time.perf_counter() - started
        segments = [parse_sortformer_segment(segment) for segment in prediction]
        write_rttm(output_dir / f"{audio_path.stem}.rttm", audio_path.stem, segments)
        files.append(
            {
                "id": audio_path.stem,
                "elapsed_seconds": elapsed,
                "speakers": len({speaker for _, _, speaker in segments}),
                "peak_gpu_memory_mib": torch.cuda.max_memory_allocated() / 1024 / 1024,
            }
        )
    return {"model": model_id, "load_seconds": load_seconds, "files": files}


def run_pyannote(model_id: str, audio_paths: list[Path], output_dir: Path) -> dict[str, object]:
    import torch
    import huggingface_hub

    original_hf_hub_download = huggingface_hub.hf_hub_download

    def hf_hub_download_compat(*args, **kwargs):
        if "use_auth_token" in kwargs and "token" not in kwargs:
            kwargs["token"] = kwargs.pop("use_auth_token")
        else:
            kwargs.pop("use_auth_token", None)
        return original_hf_hub_download(*args, **kwargs)

    huggingface_hub.hf_hub_download = hf_hub_download_compat

    from pyannote.audio import Pipeline

    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    load_start = time.perf_counter()
    pipeline = Pipeline.from_pretrained(model_id, use_auth_token=token)
    if pipeline is None:
        raise RuntimeError(f"Unable to load pyannote pipeline {model_id}")
    if torch.cuda.is_available():
        pipeline.to(torch.device("cuda"))
    load_seconds = time.perf_counter() - load_start
    pipeline("/opt/DiariZen/example/EN2002a_30s.wav")

    files = []
    for audio_path in audio_paths:
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
        started = time.perf_counter()
        annotation = pipeline(str(audio_path))
        elapsed = time.perf_counter() - started
        segments = sorted(
            (turn.start, turn.end, str(speaker))
            for turn, _, speaker in annotation.itertracks(yield_label=True)
        )
        write_rttm(output_dir / f"{audio_path.stem}.rttm", audio_path.stem, segments)
        files.append(
            {
                "id": audio_path.stem,
                "elapsed_seconds": elapsed,
                "speakers": len({speaker for _, _, speaker in segments}),
                "peak_gpu_memory_mib": torch.cuda.max_memory_allocated() / 1024 / 1024
                if torch.cuda.is_available()
                else 0.0,
            }
        )
    return {"model": model_id, "load_seconds": load_seconds, "files": files}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["diarizen", "sortformer", "pyannote"])
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("audio", nargs="+", type=Path)
    parser.add_argument("--model-id")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    if args.mode == "diarizen":
        result = run_diarizen(args.model_id or "BUT-FIT/diarizen-wavlm-large-s80-md", args.audio, args.output_dir)
    elif args.mode == "sortformer":
        result = run_sortformer(args.model_id or "nvidia/diar_sortformer_4spk-v1", args.audio, args.output_dir)
    else:
        if not args.model_id:
            raise SystemExit("--model-id is required for pyannote mode")
        result = run_pyannote(args.model_id, args.audio, args.output_dir)
    result_path = args.output_dir / "timings.json"
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True))
    print(result_path.read_text())


if __name__ == "__main__":
    main()
