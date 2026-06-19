#!/usr/bin/env python3
"""Convert Amazon Transcribe speaker-label JSON to RTTM and word JSON."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def convert(input_path: Path, recording_id: str, rttm_path: Path, words_path: Path) -> None:
    data = json.loads(input_path.read_text())
    speaker_for_start: dict[str, str] = {}
    segments = data.get("results", {}).get("speaker_labels", {}).get("segments", [])
    with rttm_path.open("w") as rttm:
        for segment in segments:
            speaker = segment.get("speaker_label")
            start = float(segment["start_time"])
            end = float(segment["end_time"])
            rttm.write(f"SPEAKER {recording_id} 1 {start:.3f} {end - start:.3f} <NA> <NA> {speaker} <NA> <NA>\n")
            for item in segment.get("items", []):
                if "start_time" in item:
                    speaker_for_start[item["start_time"]] = speaker

    words = []
    for item in data.get("results", {}).get("items", []):
        if item.get("type") != "pronunciation":
            continue
        start = item["start_time"]
        words.append(
            {
                "start": float(start),
                "end": float(item["end_time"]),
                "word": item.get("alternatives", [{}])[0].get("content", ""),
                "speaker": speaker_for_start.get(start),
            }
        )
    words_path.write_text(json.dumps({"source": str(input_path), "words": words}, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("recording_id")
    parser.add_argument("rttm", type=Path)
    parser.add_argument("words", type=Path)
    args = parser.parse_args()
    convert(args.input, args.recording_id, args.rttm, args.words)


if __name__ == "__main__":
    main()
