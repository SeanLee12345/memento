import unittest
from unittest import mock

import worker


class WorkerTests(unittest.TestCase):
    def test_merge_turns_merges_nearby_same_speaker(self):
        turns = [
            (0.0, 1.0, "speaker_0"),
            (1.4, 2.0, "speaker_0"),
            (3.5, 4.0, "speaker_1"),
        ]

        segments = worker.merge_turns(turns, {"speaker_0": 0, "speaker_1": 1})

        self.assertEqual(segments, [
            {"start": 0.0, "end": 2.0, "speakerIndex": 0},
            {"start": 3.5, "end": 4.0, "speakerIndex": 1},
        ])

    def test_merge_turns_never_exceeds_canary_audio_limit(self):
        segments = worker.merge_turns(
            [(0.0, 80.0, "speaker_0")],
            {"speaker_0": 0},
        )

        self.assertEqual(len(segments), 3)
        self.assertTrue(all(
            float(segment["end"]) - float(segment["start"])
            <= worker.MAX_CANARY_AUDIO_SECONDS
            for segment in segments
        ))

    def test_parse_sortformer_segment_accepts_string_and_tuple(self):
        self.assertEqual(
            worker.parse_sortformer_segment("1.25 2.50 speaker_1"),
            (1.25, 2.5, "speaker_1"),
        )
        self.assertEqual(
            worker.parse_sortformer_segment((3, 4, "speaker_0")),
            (3.0, 4.0, "speaker_0"),
        )

    @mock.patch.object(worker, "upload_json")
    def test_success_status_is_terminal_and_names_models(self, upload_json):
        worker.write_success_status(
            {
                "jobId": "job-1",
                "audioKey": "audio.wav",
                "statusKey": "jobs/job-1/status.json",
            },
            "results/job-1/result.json",
            {"processedAt": "2026-06-18T10:00:00Z"},
        )

        payload, key, local_name = upload_json.call_args.args
        self.assertEqual(payload["state"], "done")
        self.assertEqual(payload["diarizationModel"], worker.DIARIZATION_MODEL)
        self.assertEqual(payload["transcriptionModel"], worker.TRANSCRIPTION_MODEL)
        self.assertEqual(key, "jobs/job-1/status.json")
        self.assertEqual(local_name, "done-status.json")


if __name__ == "__main__":
    unittest.main()
