# AWS Post-Stream Speech Worker

The EC2 worker uses:

- `nvidia/diar_streaming_sortformer_4spk-v2.1` for speaker intervals.
- `nvidia/canary-qwen-2.5b` for English transcription with punctuation.

It runs in `/data/canary311`, reads `diarizen/jobs/pending.json`, and preserves
the existing S3 result contract. Canary inputs are capped at 35 seconds because
the model was trained with audio up to 40 seconds.

Deploy both files to `/opt/diarizen`, preserving the existing systemd unit:

```bash
aws s3 cp worker.py s3://meta-glasses-transcribe-620969609288/diarizen/deploy/worker.py
aws s3 cp run.sh s3://meta-glasses-transcribe-620969609288/diarizen/deploy/run.sh
```

Before replacing deployed files, create timestamped backups. Validate with a
unique job ID through the normal `audio -> spec -> pending -> result` path.
