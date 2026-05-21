# Diarizen EC2 Starter Lambda

This Lambda is invoked by S3 when `diarizen/jobs/pending.json` is uploaded.
It starts the diarization EC2 instance and schedules a delayed self-invocation
that stops the instance after 180 seconds.

It also accepts `{"action":"stopNow"}` so EventBridge can stop the same instance
on a fixed schedule as a cost guard.

The deployed Lambda needs:

- Timeout: at least 190 seconds
- `ec2:StartInstances` and `ec2:StopInstances` on `i-0c400af918e775f20`
- `lambda:InvokeFunction` on `DiarizenStartEC2`

The S3 trigger is:

- Bucket: `meta-glasses-transcribe-620969609288`
- Event: `s3:ObjectCreated:Put`
- Prefix: `diarizen/jobs/`
- Suffix: `pending.json`

Nightly cost guard:

- Rule: `StopDiarizenJobNightly`
- Schedule: `cron(0 5 * * ? *)`
- Target payload: `{"action":"stopNow"}`
