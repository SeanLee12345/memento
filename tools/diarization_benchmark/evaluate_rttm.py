#!/usr/bin/env python3
"""Select VoxConverse clips and score hypothesis RTTM files."""

from __future__ import annotations

import argparse
import json
import wave
from collections import defaultdict
from functools import lru_cache
from pathlib import Path


def read_rttm(path: Path) -> list[tuple[float, float, str]]:
    turns: list[tuple[float, float, str]] = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            continue
        start = float(fields[3])
        turns.append((start, start + float(fields[4]), fields[7]))
    return turns


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        return audio.getnframes() / audio.getframerate()


def activity(turns: list[tuple[float, float, str]], step: float, duration: float) -> list[set[str]]:
    frames = [set() for _ in range(int(duration / step) + 1)]
    for start, end, speaker in turns:
        first = max(0, int(start / step))
        last = min(len(frames), int((end + step - 1e-9) / step))
        for index in range(first, last):
            frames[index].add(speaker)
    return frames


def score(reference: Path, hypothesis: Path, duration: float, step: float = 0.01) -> dict[str, float | int]:
    ref = activity(read_rttm(reference), step, duration)
    hyp = activity(read_rttm(hypothesis), step, duration)
    ref_speakers = sorted({speaker for frame in ref for speaker in frame})
    hyp_speakers = sorted({speaker for frame in hyp for speaker in frame})

    overlap: dict[tuple[str, str], int] = defaultdict(int)
    for ref_frame, hyp_frame in zip(ref, hyp):
        for ref_speaker in ref_frame:
            for hyp_speaker in hyp_frame:
                overlap[(ref_speaker, hyp_speaker)] += 1

    size = max(len(ref_speakers), len(hyp_speakers))
    weights = [
        [overlap.get((ref_speaker, hyp_speaker), 0) for ref_speaker in ref_speakers]
        + [0] * (size - len(ref_speakers))
        for hyp_speaker in hyp_speakers
    ]
    weights.extend([[0] * size for _ in range(size - len(weights))])

    @lru_cache(maxsize=None)
    def best_assignment(row: int, used_columns: int) -> tuple[int, tuple[int, ...]]:
        if row == size:
            return 0, ()
        best_score = -1
        best_columns: tuple[int, ...] = ()
        for column in range(size):
            if used_columns & (1 << column):
                continue
            remaining_score, remaining_columns = best_assignment(row + 1, used_columns | (1 << column))
            candidate_score = weights[row][column] + remaining_score
            if candidate_score > best_score:
                best_score = candidate_score
                best_columns = (column,) + remaining_columns
        return best_score, best_columns

    _, assigned_columns = best_assignment(0, 0)
    mapping = {
        hyp_speaker: ref_speakers[assigned_columns[index]]
        for index, hyp_speaker in enumerate(hyp_speakers)
        if assigned_columns[index] < len(ref_speakers)
    }

    missed = false_alarm = confusion = reference_speaker_time = 0
    overlap_frames = 0
    for ref_frame, hyp_frame in zip(ref, hyp):
        mapped_hyp = {mapping.get(speaker, f"hyp:{speaker}") for speaker in hyp_frame}
        reference_speaker_time += len(ref_frame)
        overlap_frames += len(ref_frame) > 1
        matched = len(ref_frame & mapped_hyp)
        missed += max(0, len(ref_frame) - len(mapped_hyp))
        false_alarm += max(0, len(mapped_hyp) - len(ref_frame))
        confusion += min(len(ref_frame), len(mapped_hyp)) - matched

    denominator = max(1, reference_speaker_time)
    return {
        "reference_speakers": len(ref_speakers),
        "hypothesis_speakers": len(hyp_speakers),
        "der_percent": 100.0 * (missed + false_alarm + confusion) / denominator,
        "miss_percent": 100.0 * missed / denominator,
        "false_alarm_percent": 100.0 * false_alarm / denominator,
        "confusion_percent": 100.0 * confusion / denominator,
        "overlap_audio_percent": 100.0 * overlap_frames / len(ref),
    }


def select(audio_dir: Path, reference_dir: Path, minimum: float, maximum: float, count: int) -> list[dict[str, object]]:
    candidates: list[dict[str, object]] = []
    for audio_path in sorted(audio_dir.glob("*.wav")):
        reference_path = reference_dir / f"{audio_path.stem}.rttm"
        if not reference_path.exists():
            continue
        duration = wav_duration(audio_path)
        if not minimum <= duration <= maximum:
            continue
        turns = read_rttm(reference_path)
        speakers = len({speaker for _, _, speaker in turns})
        frames = activity(turns, 0.1, duration)
        overlap = 100.0 * sum(len(frame) > 1 for frame in frames) / len(frames)
        candidates.append(
            {
                "id": audio_path.stem,
                "duration_seconds": duration,
                "speakers": speakers,
                "overlap_audio_percent": overlap,
            }
        )
    candidates.sort(key=lambda item: (item["speakers"], item["overlap_audio_percent"]), reverse=True)
    return candidates[:count]


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    select_parser = subparsers.add_parser("select")
    select_parser.add_argument("audio_dir", type=Path)
    select_parser.add_argument("reference_dir", type=Path)
    select_parser.add_argument("--minimum", type=float, default=240.0)
    select_parser.add_argument("--maximum", type=float, default=420.0)
    select_parser.add_argument("--count", type=int, default=10)

    score_parser = subparsers.add_parser("score")
    score_parser.add_argument("reference", type=Path)
    score_parser.add_argument("hypothesis", type=Path)
    score_parser.add_argument("audio", type=Path)

    args = parser.parse_args()
    if args.command == "select":
        result = select(args.audio_dir, args.reference_dir, args.minimum, args.maximum, args.count)
    else:
        result = score(args.reference, args.hypothesis, wav_duration(args.audio))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
