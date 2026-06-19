#!/usr/bin/env python3
"""Score RTTM files with pyannote.metrics for benchmark verification."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from pyannote.core import Annotation, Segment
from pyannote.metrics.diarization import DiarizationErrorRate


def annotation_from_rttm(path: Path) -> Annotation:
    annotation = Annotation(uri=path.stem)
    for index, line in enumerate(path.read_text().splitlines()):
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            continue
        start = float(fields[3])
        end = start + float(fields[4])
        annotation[Segment(start, end), index] = fields[7]
    return annotation


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("hypothesis", type=Path)
    args = parser.parse_args()

    metric = DiarizationErrorRate(collar=0.0, skip_overlap=False)
    detail = metric(
        annotation_from_rttm(args.reference),
        annotation_from_rttm(args.hypothesis),
        detailed=True,
    )
    result = {key: float(value) for key, value in detail.items()}
    result["der_percent"] = 100.0 * result["diarization error rate"]
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
