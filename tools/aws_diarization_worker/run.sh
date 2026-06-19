#!/bin/bash
set -u

export PATH=/data/canary311/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HF_HOME=/data/hf
export TMPDIR=/data/tmp

BUCKET=meta-glasses-transcribe-620969609288
REGION=us-west-1
LOG=/var/log/diarizen-worker.log
IDLE_TIMEOUT=300
POLL_INTERVAL=10

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }

log "Sortformer + Canary worker started (poll=${POLL_INTERVAL}s, idle=${IDLE_TIMEOUT}s)"
last_activity=$(date +%s)

while true; do
  if /usr/bin/aws s3 ls "s3://${BUCKET}/diarizen/jobs/pending.json" --region "$REGION" 2>/dev/null | grep -q pending; then
    log "Job found, running Sortformer + Canary worker"
    /data/canary311/bin/python /opt/diarizen/worker.py >> "$LOG" 2>&1
    exit_code=$?
    last_activity=$(date +%s)
    log "Worker run completed exit=${exit_code}"
  fi

  now=$(date +%s)
  elapsed=$((now - last_activity))
  if [ "$elapsed" -ge "$IDLE_TIMEOUT" ]; then
    log "Idle ${elapsed}s, staying alive for warm EC2 poller"
    last_activity=$(date +%s)
  fi
  sleep "$POLL_INTERVAL"
done
