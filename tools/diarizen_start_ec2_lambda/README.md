# Diarizen EC2 Starter Lambda

This Lambda is invoked by S3 when `diarizen/jobs/pending.json` is uploaded.
It starts the diarization EC2 instance and schedules a delayed self-invocation
watchdog after 840 seconds.

The iOS app also writes durable per-job metadata:

- `diarizen/jobs/<jobId>/spec.json`
- `diarizen/jobs/<jobId>/status.json`
- `diarizen/results/<jobId>/result.json`

`pending.json` remains the legacy worker trigger pointer. The Lambda reads the
job ID and S3 keys from that trigger, logs them to CloudWatch, and updates the
per-job status object. The watchdog checks whether `result.json` exists before
stopping EC2. If the result is missing, it records `processing` and renews the
watchdog for up to four cycles; only the final cycle writes `failed` with
`errorKind=ec2StoppedBeforeResult` and stops the instance. This prevents the
old silent app-side timeout where EC2 was stopped at 14 minutes while iOS kept
polling until 15 minutes.

It also accepts `{"action":"stopNow"}` so EventBridge can stop the same instance
on a fixed schedule as a cost guard.

After the app downloads a completed diarization result, it invokes
`{"action":"stopAfterDiarizationComplete","jobId":"..."}`. The Lambda stops
EC2 immediately when neither live face nor live speaker lease is active. If a
lease is still active, shutdown is deferred to that lease's existing expiry;
the 840-second diarization watchdog remains a crash/network fallback. All stop
paths first use the EC2 API. If instance stop protection blocks that API, the
Lambda sends `sudo shutdown -h now` through SSM; the instance's
`InstanceInitiatedShutdownBehavior` must remain `stop`.

For live stream-time embedding workers, the Lambda accepts independent
speaker and face actions that share the same EC2 instance:

- `{"action":"startLive","sessionId":"..."}` — speaker worker on port 8090.
  Tags the instance with `MetaGlassesLiveSessionId`/`MetaGlassesLiveExpiresAt`
  and schedules a `stopLiveAfterDelay` for 600 seconds.
- `{"action":"startLiveFace","sessionId":"..."}` — face (AdaFace) worker on
  port 8080. Uses `MetaGlassesLiveFaceSessionId`/`MetaGlassesLiveFaceExpiresAt`
  and schedules a `stopLiveFaceAfterDelay`.
- `{"action":"describeLive"}` — returns instance state plus both lease tags.
- `{"action":"refreshLive","sessionId":"..."}` /
  `{"action":"refreshLiveFace","sessionId":"..."}` — extends the named lease.
- `{"action":"releaseLive"}` / `{"action":"releaseLiveFace"}` — clears the
  named lease without stopping EC2 (used when post-session diarization will
  reuse the instance).
- `{"action":"releaseLiveAndMaybeStop","service":"speaker"|"face"}` — clears
  the named lease and stops EC2 only if the OTHER service's lease is also
  idle. This is the normal stream-end teardown when no diarization job is
  queued. It keeps the EC2 instance alive as long as either worker still
  holds an active lease.
- `{"action":"stopNow"}` — emergency cut-off; stops EC2 and clears both tag
  sets unconditionally. Used by the EventBridge nightly cost guard.
- `{"action":"stopAfterDiarizationComplete","jobId":"..."}` — normal
  post-stream completion path. Stops immediately unless a live embedding lease
  is still active.

If the app crashes or loses network, each live-session expiry triggers a
delayed stop after 600 seconds — but `stopLiveAfterDelay` and
`stopLiveFaceAfterDelay` both verify the other service's lease before stopping
EC2, so a crash on one service does not interrupt the other.

The deployed Lambda needs:

- Timeout: 900 seconds
- `ec2:StartInstances`, `ec2:StopInstances`, `ec2:CreateTags`, and
  `ec2:DeleteTags` on `i-0c400af918e775f20`
- `ec2:DescribeInstances` on `*`
- `lambda:InvokeFunction` on `DiarizenStartEC2`
- `ssm:SendCommand` on `i-0c400af918e775f20` and the AWS-managed
  `AWS-RunShellScript` document, for the stop-protection fallback
- `s3:GetObject`, `s3:PutObject`, and `s3:HeadObject` on
  `arn:aws:s3:::meta-glasses-transcribe-620969609288/diarizen/*`

The S3 trigger is:

- Bucket: `meta-glasses-transcribe-620969609288`
- Event: `s3:ObjectCreated:Put`
- Prefix: `diarizen/jobs/`
- Suffix: `pending.json`

Nightly cost guard:

- Rule: `StopDiarizenJobNightly`
- Schedule: `cron(0 5 * * ? *)`
- Target payload: `{"action":"stopNow"}`

For iOS live EC2 lifecycle control, the Cognito identity role used by the app
also needs `lambda:InvokeFunction` on `DiarizenStartEC2`.
