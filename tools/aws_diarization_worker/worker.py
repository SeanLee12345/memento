#!/usr/bin/env python3
"""Post-stream NVIDIA Sortformer + Canary-Qwen worker.

Reads the current S3 job, runs Streaming Sortformer v2.1 for speaker turns,
transcribes bounded turns with Canary-Qwen 2.5B, and writes the existing result
contract plus explicit model metadata. The process runs in the shared NeMo
Python 3.11 environment at /data/canary311.
"""

from __future__ import annotations

import datetime
import gc
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

import numpy as np
import soundfile as sf

BUCKET = "meta-glasses-transcribe-620969609288"
REGION = "us-west-1"
JOB_KEY = "diarizen/jobs/pending.json"
AWS = "/usr/bin/aws"

DIARIZATION_MODEL = "nvidia/diar_streaming_sortformer_4spk-v2.1"
TRANSCRIPTION_MODEL = "nvidia/canary-qwen-2.5b"
PIPELINE_VERSION = "sortformer-canary-v1"
MERGE_GAP_SECONDS = 1.0
MAX_CANARY_AUDIO_SECONDS = 35.0
MAX_NEW_TOKENS = 256


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def s3_cp(source: str, destination: str) -> None:
    subprocess.run([AWS, "s3", "cp", source, destination, "--region", REGION], check=True)


def s3_rm(key: str) -> None:
    subprocess.run(
        [AWS, "s3", "rm", f"s3://{BUCKET}/{key}", "--region", REGION],
        check=False,
    )


def s3_uri(key: str) -> str:
    return f"s3://{BUCKET}/{key}"


def upload_json(payload: object, key: str, local_name: str) -> None:
    path = Path("/tmp") / local_name
    path.write_text(json.dumps(payload, indent=2))
    s3_cp(str(path), s3_uri(key))


def patch_overrides_signature_checks() -> None:
    """NeMo imports NVIDIA One Logger with stricter override checks than needed."""
    try:
        import overrides as overrides_package
        import overrides.overrides as overrides_module

        def override_without_checks(method=None, *, check_signature=True, check_at_runtime=False):
            del check_signature, check_at_runtime
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


def split_turn(start: float, end: float, speaker: str) -> list[tuple[float, float, str]]:
    pieces: list[tuple[float, float, str]] = []
    cursor = start
    while cursor < end:
        piece_end = min(end, cursor + MAX_CANARY_AUDIO_SECONDS)
        pieces.append((cursor, piece_end, speaker))
        cursor = piece_end
    return pieces


def merge_turns(
    turns: list[tuple[float, float, str]],
    speaker_indices: dict[str, int],
) -> list[dict[str, object]]:
    merged: list[dict[str, object]] = []
    for raw_start, raw_end, speaker in turns:
        for start, end, split_speaker in split_turn(raw_start, raw_end, speaker):
            index = speaker_indices[split_speaker]
            if (
                merged
                and merged[-1]["speakerIndex"] == index
                and start - float(merged[-1]["end"]) <= MERGE_GAP_SECONDS
                and end - float(merged[-1]["start"]) <= MAX_CANARY_AUDIO_SECONDS
            ):
                merged[-1]["end"] = end
            else:
                merged.append({"start": start, "end": end, "speakerIndex": index})
    return merged


def run_sortformer(audio_path: str) -> tuple[list[tuple[float, float, str]], float, float]:
    patch_overrides_signature_checks()
    import torch
    from nemo.collections.asr.models import SortformerEncLabelModel

    load_started = time.perf_counter()
    model = SortformerEncLabelModel.from_pretrained(DIARIZATION_MODEL).eval().cuda()
    model.sortformer_modules.chunk_len = 340
    model.sortformer_modules.chunk_right_context = 40
    model.sortformer_modules.fifo_len = 40
    model.sortformer_modules.spkcache_update_period = 300
    load_seconds = time.perf_counter() - load_started

    inference_started = time.perf_counter()
    prediction = model.diarize(audio=[audio_path], batch_size=1)[0]
    torch.cuda.synchronize()
    inference_seconds = time.perf_counter() - inference_started
    turns = sorted((parse_sortformer_segment(item) for item in prediction), key=lambda item: item[0])

    del model
    gc.collect()
    torch.cuda.empty_cache()
    return turns, load_seconds, inference_seconds


def transcribe_segments(
    audio_path: str,
    segments: list[dict[str, object]],
) -> tuple[list[dict[str, object]], float, float]:
    import torch
    from nemo.collections.speechlm2.models import SALM

    audio, sample_rate = sf.read(audio_path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    load_started = time.perf_counter()
    model = SALM.from_pretrained(TRANSCRIPTION_MODEL).to("cuda").eval()
    load_seconds = time.perf_counter() - load_started
    tag = model.audio_locator_tag

    prompts = []
    with tempfile.TemporaryDirectory(prefix="canary_segments_") as temp_dir:
        for index, segment in enumerate(segments):
            start = float(segment["start"])
            end = float(segment["end"])
            if end - start > MAX_CANARY_AUDIO_SECONDS + 0.001:
                raise ValueError(f"Canary segment {index} exceeds {MAX_CANARY_AUDIO_SECONDS}s")
            first_sample = max(0, min(len(audio), round(start * sample_rate)))
            last_sample = max(first_sample, min(len(audio), round(end * sample_rate)))
            if last_sample <= first_sample:
                continue
            clip_path = Path(temp_dir) / f"segment_{index:04d}.wav"
            sf.write(clip_path, audio[first_sample:last_sample], sample_rate, subtype="PCM_16")
            prompts.append((segment, [{
                "role": "user",
                "content": f"Transcribe the following: {tag}",
                "audio": [str(clip_path)],
            }]))

        inference_started = time.perf_counter()
        transcribed: list[dict[str, object]] = []
        for segment, prompt in prompts:
            answer_ids = model.generate(prompts=[prompt], max_new_tokens=MAX_NEW_TOKENS)
            text = model.tokenizer.ids_to_text(answer_ids[0].cpu()).strip()
            if not text:
                print(
                    f"Canary returned empty text start={segment['start']} end={segment['end']} "
                    f"speaker={segment['speakerIndex']}; omitting non-transcript interval",
                    flush=True,
                )
                continue
            transcribed.append({**segment, "text": text})
        torch.cuda.synchronize()
        inference_seconds = time.perf_counter() - inference_started

    del model
    gc.collect()
    torch.cuda.empty_cache()
    return transcribed, load_seconds, inference_seconds


def upload_speaker_clips(
    job_id: str,
    audio_path: str,
    turns: list[tuple[float, float, str]],
    speaker_indices: dict[str, int],
) -> dict[str, str]:
    audio, sample_rate = sf.read(audio_path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    keys: dict[str, str] = {}
    for speaker, index in speaker_indices.items():
        clips = []
        remaining_seconds = 8.0
        for start, end, turn_speaker in turns:
            if turn_speaker != speaker or remaining_seconds <= 0:
                continue
            duration = min(max(0.0, end - start), remaining_seconds)
            if duration <= 0:
                continue
            first_sample = max(0, round(start * sample_rate))
            last_sample = min(len(audio), round((start + duration) * sample_rate))
            if last_sample > first_sample:
                clips.append(audio[first_sample:last_sample])
                remaining_seconds -= duration
        if not clips:
            continue
        clip_path = Path("/tmp") / f"speaker_{index}_clip.wav"
        sf.write(clip_path, np.concatenate(clips), sample_rate, subtype="PCM_16")
        key = f"diarizen/results/{job_id}/speaker_{index}_clip.wav"
        s3_cp(str(clip_path), s3_uri(key))
        keys[str(index)] = key
    return keys


def write_failure(job: dict[str, object], error: Exception) -> None:
    job_id = str(job.get("jobId", "unknown"))
    message = f"{type(error).__name__}: {error}"
    payload = {
        "jobId": job_id,
        "state": "failed",
        "failedAt": now_iso(),
        "updatedAt": now_iso(),
        "errorKind": "sortformerCanaryWorkerFailed",
        "errorMessage": message,
        "workerHostname": socket.gethostname(),
        "workerProcessId": os.getpid(),
    }
    status_key = str(job.get("statusKey") or f"diarizen/jobs/{job_id}/status.json")
    error_key = str(job.get("errorKey") or f"diarizen/jobs/{job_id}/error.json")
    upload_json(payload, status_key, "failed-status.json")
    upload_json({**payload, "traceback": traceback.format_exc()}, error_key, "worker-error.json")


def write_success_status(job: dict[str, object], result_key: str, result: dict[str, object]) -> None:
    job_id = str(job["jobId"])
    finished_at = str(result["processedAt"])
    status = {
        "jobId": job_id,
        "state": "done",
        "audioKey": job.get("audioKey"),
        "resultKey": result_key,
        "statusKey": job.get("statusKey"),
        "conversationSessionId": job.get("conversationSessionId"),
        "audioDurationSeconds": job.get("audioDurationSeconds"),
        "audioByteCount": job.get("audioByteCount"),
        "createdAt": job.get("createdAt"),
        "finishedAt": finished_at,
        "updatedAt": finished_at,
        "workerHostname": socket.gethostname(),
        "workerProcessId": os.getpid(),
        "pipelineVersion": PIPELINE_VERSION,
        "diarizationModel": DIARIZATION_MODEL,
        "transcriptionModel": TRANSCRIPTION_MODEL,
    }
    status_key = str(job.get("statusKey") or f"diarizen/jobs/{job_id}/status.json")
    upload_json(status, status_key, "done-status.json")


def main() -> None:
    print(f"=== Sortformer + Canary worker {now_iso()} ===", flush=True)
    s3_cp(s3_uri(JOB_KEY), "/tmp/job.json")
    job = json.loads(Path("/tmp/job.json").read_text())
    job_id = str(job["jobId"])
    audio_key = str(job["audioKey"])
    result_key = str(job.get("resultKey") or f"diarizen/results/{job_id}/result.json")
    audio_path = "/tmp/session.wav"
    s3_cp(s3_uri(audio_key), audio_path)

    try:
        turns, sortformer_load, sortformer_inference = run_sortformer(audio_path)
        if not turns:
            raise RuntimeError("Sortformer returned no speech intervals")
        speaker_indices: dict[str, int] = {}
        for _, _, speaker in turns:
            speaker_indices.setdefault(speaker, len(speaker_indices))
        segments = merge_turns(turns, speaker_indices)
        transcribed, canary_load, canary_inference = transcribe_segments(audio_path, segments)
        if not transcribed:
            raise RuntimeError("Canary returned no usable transcript text")
        clip_keys = upload_speaker_clips(job_id, audio_path, turns, speaker_indices)
        result = {
            "jobId": job_id,
            "speakerCount": len(speaker_indices),
            "segments": transcribed,
            "speakerClipKeys": clip_keys,
            "processedAt": now_iso(),
            "pipelineVersion": PIPELINE_VERSION,
            "diarizationModel": DIARIZATION_MODEL,
            "transcriptionModel": TRANSCRIPTION_MODEL,
            "transcriptionSource": "awsCanaryQwen",
            "timings": {
                "sortformerLoadSeconds": sortformer_load,
                "sortformerInferenceSeconds": sortformer_inference,
                "canaryLoadSeconds": canary_load,
                "canaryInferenceSeconds": canary_inference,
            },
        }
        upload_json(result, result_key, "result.json")
        write_success_status(job, result_key, result)
        s3_rm(JOB_KEY)
        print(
            f"Completed job={job_id} speakers={len(speaker_indices)} "
            f"segments={len(transcribed)} result={result_key}",
            flush=True,
        )
    except Exception as error:
        write_failure(job, error)
        s3_rm(JOB_KEY)
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Worker error: {error}", flush=True)
        traceback.print_exc()
        sys.exit(1)
