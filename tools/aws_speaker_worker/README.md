# AWS Speaker Embedding Worker

This worker exposes live TitaNet speaker embeddings for the iOS app:

```text
GET  /health
POST /speaker/embed
Authorization: Bearer <SPEAKER_WORKER_API_KEY>
Content-Type: multipart/form-data
```

The app sends 3-second 16 kHz mono WAV chunks and expects a normalized 192-d
embedding from:

```text
nvidia/speakerverification_en_titanet_large
```

## Run On The EC2 Instance

Use the existing `m7i-flex.large` CPU instance for now:

```sh
cd tools/aws_speaker_worker
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-cpu.txt
pip install --index-url https://download.pytorch.org/whl/cpu torch torchaudio
export SPEAKER_WORKER_API_KEY='replace-me'
uvicorn app:app --host 0.0.0.0 --port 8090
```

For live use, run it as a systemd service on port `8090`. The app starts the EC2
instance once at stream activation, polls `http://<public-ip>:8090/health`, sends
speech chunks every ~2 seconds while speech is active, and calls the Lambda
`stopNow` action when the stream ends. The EC2 security group must allow inbound
TCP `8090` from the development/test network.

## App Settings

In the app settings:

- Enable `AWS live speaker embeddings`.
- Leave the endpoint override empty when using Lambda lifecycle; the app will use
  the public IP returned by `DiarizenStartEC2`.
- The app uses the development default `SPEAKER_WORKER_API_KEY` unless a saved
  override exists.

The Lambda needs the `startLive` action from `tools/diarizen_start_ec2_lambda`.
The app's Cognito identity role also needs `lambda:InvokeFunction` on that Lambda.
