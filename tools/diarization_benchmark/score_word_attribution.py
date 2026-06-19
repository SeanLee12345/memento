#!/usr/bin/env python3
"""Score who-said-what attribution for ASR words against RTTM labels."""

from __future__ import annotations

import argparse
import json
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


def speakers_at(turns: list[tuple[float, float, str]], timestamp: float) -> set[str]:
    return {speaker for start, end, speaker in turns if start <= timestamp <= end}


def best_mapping(reference: list[tuple[float, float, str]], hypothesis: list[tuple[float, float, str]]) -> dict[str, str]:
    ref_speakers = sorted({speaker for _, _, speaker in reference})
    hyp_speakers = sorted({speaker for _, _, speaker in hypothesis})
    overlap: dict[tuple[str, str], float] = defaultdict(float)

    for ref_start, ref_end, ref_speaker in reference:
        for hyp_start, hyp_end, hyp_speaker in hypothesis:
            amount = max(0.0, min(ref_end, hyp_end) - max(ref_start, hyp_start))
            if amount > 0:
                overlap[(ref_speaker, hyp_speaker)] += amount

    size = max(len(ref_speakers), len(hyp_speakers))
    weights = [
        [overlap.get((ref_speaker, hyp_speaker), 0.0) for ref_speaker in ref_speakers]
        + [0.0] * (size - len(ref_speakers))
        for hyp_speaker in hyp_speakers
    ]
    weights.extend([[0.0] * size for _ in range(size - len(weights))])

    @lru_cache(maxsize=None)
    def assign(row: int, used_columns: int) -> tuple[float, tuple[int, ...]]:
        if row == size:
            return 0.0, ()
        best_score = -1.0
        best_columns: tuple[int, ...] = ()
        for column in range(size):
            if used_columns & (1 << column):
                continue
            remaining_score, remaining_columns = assign(row + 1, used_columns | (1 << column))
            score = weights[row][column] + remaining_score
            if score > best_score:
                best_score = score
                best_columns = (column,) + remaining_columns
        return best_score, best_columns

    _, columns = assign(0, 0)
    return {
        hyp_speaker: ref_speakers[columns[index]]
        for index, hyp_speaker in enumerate(hyp_speakers)
        if columns[index] < len(ref_speakers)
    }


def read_words(path: Path) -> list[dict[str, object]]:
    data = json.loads(path.read_text())
    if isinstance(data, dict):
        words = data.get("words", [])
    else:
        words = data
    return [
        word
        for word in words
        if word.get("start") is not None and word.get("end") is not None and str(word.get("word", "")).strip()
    ]


def score_words(reference_path: Path, hypothesis_path: Path, words_path: Path) -> dict[str, object]:
    reference = read_rttm(reference_path)
    hypothesis = read_rttm(hypothesis_path)
    mapping = best_mapping(reference, hypothesis)
    words = read_words(words_path)

    scored = correct = missed = wrong = overlap_ref = 0
    weighted_total = weighted_correct = 0.0
    examples: list[dict[str, object]] = []

    for word in words:
        start = float(word["start"])
        end = float(word["end"])
        midpoint = (start + end) / 2.0
        duration = max(0.01, end - start)
        ref = speakers_at(reference, midpoint)
        hyp = speakers_at(hypothesis, midpoint)
        if not ref:
            continue
        scored += 1
        weighted_total += duration
        if len(ref) > 1:
            overlap_ref += 1
        mapped_hyp = {mapping.get(speaker, f"unmapped:{speaker}") for speaker in hyp}
        if mapped_hyp & ref:
            correct += 1
            weighted_correct += duration
        elif not mapped_hyp:
            missed += 1
        else:
            wrong += 1
            if len(examples) < 8:
                examples.append(
                    {
                        "word": word.get("word"),
                        "start": start,
                        "end": end,
                        "reference": sorted(ref),
                        "hypothesis": sorted(mapped_hyp),
                    }
                )

    return {
        "reference_speakers": len({speaker for _, _, speaker in reference}),
        "hypothesis_speakers": len({speaker for _, _, speaker in hypothesis}),
        "words_scored": scored,
        "word_speaker_accuracy_percent": 100.0 * correct / max(1, scored),
        "duration_weighted_accuracy_percent": 100.0 * weighted_correct / max(0.01, weighted_total),
        "wrong_speaker_words": wrong,
        "missed_speaker_words": missed,
        "overlap_reference_words": overlap_ref,
        "mapping": mapping,
        "wrong_examples": examples,
    }


def transcribe_with_whisper(audio_path: Path, output_path: Path, model_name: str) -> None:
    import whisper

    model = whisper.load_model(model_name)
    result = model.transcribe(str(audio_path), word_timestamps=True, language="en")
    words = []
    for segment in result.get("segments", []):
        for word in segment.get("words", []):
            words.append(
                {
                    "start": float(word["start"]),
                    "end": float(word["end"]),
                    "word": str(word["word"]).strip(),
                }
            )
    output_path.write_text(json.dumps({"audio": str(audio_path), "model": model_name, "words": words}, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    transcribe_parser = subparsers.add_parser("transcribe")
    transcribe_parser.add_argument("audio", type=Path)
    transcribe_parser.add_argument("output", type=Path)
    transcribe_parser.add_argument("--model", default="base.en")

    score_parser = subparsers.add_parser("score")
    score_parser.add_argument("reference", type=Path)
    score_parser.add_argument("hypothesis", type=Path)
    score_parser.add_argument("words", type=Path)

    args = parser.parse_args()
    if args.command == "transcribe":
        transcribe_with_whisper(args.audio, args.output, args.model)
    else:
        print(json.dumps(score_words(args.reference, args.hypothesis, args.words), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
