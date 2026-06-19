import boto3
import json
import time
from datetime import datetime, timezone
from urllib.parse import unquote_plus
from botocore.config import Config
from botocore.exceptions import ClientError

INSTANCE_ID = "i-0c400af918e775f20"
REGION = "us-west-1"
MAX_RUNTIME_SECONDS = 840
MAX_DIARIZATION_WATCHDOG_CYCLES = 4
LIVE_MAX_RUNTIME_SECONDS = 600

# Speaker live-session tags (existing semantics).
LIVE_SESSION_TAG = "MetaGlassesLiveSessionId"
LIVE_EXPIRES_TAG = "MetaGlassesLiveExpiresAt"

# Face live-session tags (new; tracks the AdaFace worker lease independently).
LIVE_FACE_SESSION_TAG = "MetaGlassesLiveFaceSessionId"
LIVE_FACE_EXPIRES_TAG = "MetaGlassesLiveFaceExpiresAt"


def describe_instance(ec2):
    reservations = ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"]
    instance = reservations[0]["Instances"][0]
    tags = {tag["Key"]: tag["Value"] for tag in instance.get("Tags", [])}
    return {
        "state": instance["State"]["Name"],
        "publicIp": instance.get("PublicIpAddress"),
        "privateIp": instance.get("PrivateIpAddress"),
        "liveSessionId": tags.get(LIVE_SESSION_TAG),
        "liveExpiresAt": tags.get(LIVE_EXPIRES_TAG),
        "liveFaceSessionId": tags.get(LIVE_FACE_SESSION_TAG),
        "liveFaceExpiresAt": tags.get(LIVE_FACE_EXPIRES_TAG),
    }


def lambda_client():
    return boto3.client(
        "lambda",
        region_name=REGION,
        config=Config(
            connect_timeout=5,
            read_timeout=10,
            retries={"max_attempts": 1},
        ),
    )


def s3_client():
    return boto3.client(
        "s3",
        region_name=REGION,
        config=Config(
            connect_timeout=5,
            read_timeout=10,
            retries={"max_attempts": 1},
        ),
    )


def stop_instance(ec2, reason):
    try:
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        return "ec2Api"
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code")
        message = error.response.get("Error", {}).get("Message", "")
        if code != "OperationNotPermitted" or "disableApiStop" not in message:
            raise

    # EC2 stop protection does not block an OS-initiated shutdown. The instance
    # is configured with InstanceInitiatedShutdownBehavior=stop.
    response = boto3.client("ssm", region_name=REGION).send_command(
        InstanceIds=[INSTANCE_ID],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": ["sudo shutdown -h now"]},
        Comment=f"Meta glasses worker shutdown: {reason}"[:100],
    )
    command_id = response.get("Command", {}).get("CommandId")
    print(
        f"EC2 API stop blocked by stop protection; sent in-instance shutdown "
        f"instance={INSTANCE_ID} commandId={command_id} reason={reason}"
    )
    return "ssmShutdown"


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_s3_job_context(event):
    records = event.get("Records") if isinstance(event, dict) else None
    if not records:
        return None
    record = records[0]
    bucket = record.get("s3", {}).get("bucket", {}).get("name")
    key = unquote_plus(record.get("s3", {}).get("object", {}).get("key", ""))
    if not bucket or not key:
        return None
    try:
        body = s3_client().get_object(Bucket=bucket, Key=key)["Body"].read()
        spec = json.loads(body.decode("utf-8"))
    except Exception as error:
        print(f"Could not load diarization job spec bucket={bucket} key={key}: {error}")
        return {"bucket": bucket, "triggerKey": key}
    spec["bucket"] = bucket
    spec["triggerKey"] = key
    spec.setdefault("resultKey", f"diarizen/results/{spec.get('jobId', 'unknown')}/result.json")
    spec.setdefault("statusKey", f"diarizen/jobs/{spec.get('jobId', 'unknown')}/status.json")
    return spec


def result_exists(s3, bucket, result_key):
    if not bucket or not result_key:
        return False
    try:
        s3.head_object(Bucket=bucket, Key=result_key)
        return True
    except Exception:
        return False


def put_job_status(s3, spec, state, context=None, **extra):
    if not spec:
        return
    bucket = spec.get("bucket")
    job_id = spec.get("jobId")
    status_key = spec.get("statusKey")
    if not bucket or not job_id or not status_key:
        return
    current = extra.pop("current", None) or {}
    payload = {
        "jobId": job_id,
        "state": state,
        "audioKey": spec.get("audioKey"),
        "resultKey": spec.get("resultKey"),
        "statusKey": status_key,
        "conversationSessionId": spec.get("conversationSessionId"),
        "audioDurationSeconds": spec.get("audioDurationSeconds"),
        "audioByteCount": spec.get("audioByteCount"),
        "createdAt": spec.get("createdAt"),
        "startedAt": extra.pop("startedAt", None),
        "finishedAt": extra.pop("finishedAt", None),
        "failedAt": extra.pop("failedAt", None),
        "updatedAt": now_iso(),
        "lambdaRequestId": getattr(context, "aws_request_id", None),
        "workerHostname": extra.pop("workerHostname", None),
        "workerProcessId": extra.pop("workerProcessId", None),
        "errorKind": extra.pop("errorKind", None),
        "errorMessage": extra.pop("errorMessage", None),
        "instanceState": current.get("state"),
        "publicIp": current.get("publicIp"),
        "privateIp": current.get("privateIp"),
    }
    payload.update(extra)
    s3.put_object(
        Bucket=bucket,
        Key=status_key,
        Body=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        ContentType="application/json",
    )
    print(
        f"Diarization status jobId={job_id} state={state} "
        f"statusKey={status_key} resultKey={spec.get('resultKey')}"
    )


def stop_delay_payload(context, spec, cycle=1):
    payload = {"action": "stopAfterDelay", "cycle": cycle}
    if spec:
        payload.update({
            "bucket": spec.get("bucket"),
            "jobId": spec.get("jobId"),
            "audioKey": spec.get("audioKey"),
            "resultKey": spec.get("resultKey"),
            "statusKey": spec.get("statusKey"),
            "conversationSessionId": spec.get("conversationSessionId"),
            "audioDurationSeconds": spec.get("audioDurationSeconds"),
            "audioByteCount": spec.get("audioByteCount"),
            "createdAt": spec.get("createdAt"),
        })
    return json.dumps(payload).encode("utf-8")


def spec_from_stop_event(event):
    if not isinstance(event, dict):
        return None
    job_id = event.get("jobId")
    bucket = event.get("bucket")
    if not job_id or not bucket:
        return None
    return {
        "bucket": bucket,
        "jobId": job_id,
        "audioKey": event.get("audioKey"),
        "resultKey": event.get("resultKey") or f"diarizen/results/{job_id}/result.json",
        "statusKey": event.get("statusKey") or f"diarizen/jobs/{job_id}/status.json",
        "conversationSessionId": event.get("conversationSessionId"),
        "audioDurationSeconds": event.get("audioDurationSeconds"),
        "audioByteCount": event.get("audioByteCount"),
        "createdAt": event.get("createdAt"),
    }


def set_live_expiry(ec2, session_id, session_tag, expires_tag):
    expires_at = int(time.time()) + LIVE_MAX_RUNTIME_SECONDS
    ec2.create_tags(
        Resources=[INSTANCE_ID],
        Tags=[
            {"Key": session_tag, "Value": session_id},
            {"Key": expires_tag, "Value": str(expires_at)},
        ],
    )
    return expires_at


def clear_live_tags(ec2, session_tag, expires_tag):
    ec2.delete_tags(
        Resources=[INSTANCE_ID],
        Tags=[
            {"Key": session_tag},
            {"Key": expires_tag},
        ],
    )


def schedule_live_stop(context, session_id, action="stopLiveAfterDelay"):
    lambda_client().invoke(
        FunctionName=context.invoked_function_arn,
        InvocationType="Event",
        Payload=json.dumps({"action": action, "sessionId": session_id}).encode("utf-8"),
    )


def lease_is_active(session_id, expires_at_text):
    if not session_id:
        return False
    try:
        expires_at = int(expires_at_text or "0")
    except (TypeError, ValueError):
        return False
    return int(time.time()) < expires_at


def other_lease_active(current, service):
    if service == "speaker":
        return lease_is_active(current.get("liveFaceSessionId"), current.get("liveFaceExpiresAt"))
    if service == "face":
        return lease_is_active(current.get("liveSessionId"), current.get("liveExpiresAt"))
    return (
        lease_is_active(current.get("liveSessionId"), current.get("liveExpiresAt"))
        or lease_is_active(current.get("liveFaceSessionId"), current.get("liveFaceExpiresAt"))
    )


def start_live(ec2, context, session_id, session_tag, expires_tag, schedule_action):
    try:
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
        print(f"Started {INSTANCE_ID} for live worker session={session_id}")
    except ec2.exceptions.ClientError as error:
        code = error.response["Error"]["Code"]
        if code == "IncorrectInstanceState":
            print(f"{INSTANCE_ID} already running for live worker session={session_id}")
        else:
            raise

    expires_at = set_live_expiry(ec2, session_id, session_tag, expires_tag)
    schedule_live_stop(context, session_id, action=schedule_action)
    return expires_at


def lambda_handler(event, context):
    # Keep EC2 bounded even when the worker does not shut itself down.
    ec2 = boto3.client(
        "ec2",
        region_name=REGION,
        config=Config(
            connect_timeout=5,
            read_timeout=10,
            retries={"max_attempts": 1},
        ),
    )

    if isinstance(event, dict) and event.get("action") == "stopNow":
        stop_instance(ec2, "explicit stopNow")
        clear_live_tags(ec2, LIVE_SESSION_TAG, LIVE_EXPIRES_TAG)
        clear_live_tags(ec2, LIVE_FACE_SESSION_TAG, LIVE_FACE_EXPIRES_TAG)
        print(f"Stopped {INSTANCE_ID} from explicit stopNow action")
        return {"statusCode": 200, "action": "stopped"}

    if isinstance(event, dict) and event.get("action") == "stopAfterDiarizationComplete":
        current = describe_instance(ec2)
        if other_lease_active(current, "diarization"):
            print(
                f"Deferred EC2 stop after diarization jobId={event.get('jobId')} because a live lease is active "
                f"speaker={current.get('liveSessionId')} face={current.get('liveFaceSessionId')}"
            )
            return {
                "statusCode": 200,
                "action": "deferredAfterDiarization",
                "jobId": event.get("jobId"),
                **current,
            }
        shutdown_method = stop_instance(
            ec2,
            f"diarization complete jobId={event.get('jobId')}",
        )
        clear_live_tags(ec2, LIVE_SESSION_TAG, LIVE_EXPIRES_TAG)
        clear_live_tags(ec2, LIVE_FACE_SESSION_TAG, LIVE_FACE_EXPIRES_TAG)
        print(f"Stopped {INSTANCE_ID} immediately after diarization jobId={event.get('jobId')}")
        return {
            "statusCode": 200,
            "action": "stoppedAfterDiarization",
            "jobId": event.get("jobId"),
            "shutdownMethod": shutdown_method,
            **describe_instance(ec2),
        }

    if isinstance(event, dict) and event.get("action") == "releaseLive":
        clear_live_tags(ec2, LIVE_SESSION_TAG, LIVE_EXPIRES_TAG)
        print(f"Released speaker live session tags for {INSTANCE_ID} without stopping")
        return {"statusCode": 200, "action": "releasedLive", **describe_instance(ec2)}

    if isinstance(event, dict) and event.get("action") == "releaseLiveFace":
        clear_live_tags(ec2, LIVE_FACE_SESSION_TAG, LIVE_FACE_EXPIRES_TAG)
        print(f"Released face live session tags for {INSTANCE_ID} without stopping")
        return {"statusCode": 200, "action": "releasedLiveFace", **describe_instance(ec2)}

    if isinstance(event, dict) and event.get("action") == "releaseLiveAndMaybeStop":
        # Either face or speaker has finished its live session; clear that service's
        # tags and stop EC2 only when the other service's lease is also idle.
        service = event.get("service")
        if service == "face":
            clear_live_tags(ec2, LIVE_FACE_SESSION_TAG, LIVE_FACE_EXPIRES_TAG)
        elif service == "speaker":
            clear_live_tags(ec2, LIVE_SESSION_TAG, LIVE_EXPIRES_TAG)
        else:
            return {"statusCode": 400, "errorMessage": "missing or invalid service"}
        current = describe_instance(ec2)
        if other_lease_active(current, service):
            print(
                f"Skipped EC2 stop for service={service} because other lease is still active "
                f"speaker={current.get('liveSessionId')} face={current.get('liveFaceSessionId')}"
            )
            return {"statusCode": 200, "action": "releasedKeepRunning", "service": service, **current}
        stop_instance(ec2, f"live {service} lease released")
        # Clear residual tags so the post-stop state is clean.
        clear_live_tags(ec2, LIVE_SESSION_TAG, LIVE_EXPIRES_TAG)
        clear_live_tags(ec2, LIVE_FACE_SESSION_TAG, LIVE_FACE_EXPIRES_TAG)
        print(f"Stopped {INSTANCE_ID} after service={service} released its lease and no other lease was active")
        return {"statusCode": 200, "action": "stoppedLive", "service": service, **describe_instance(ec2)}

    if isinstance(event, dict) and event.get("action") == "describeLive":
        return {
            "statusCode": 200,
            "action": "describedLive",
            **describe_instance(ec2),
        }

    if isinstance(event, dict) and event.get("action") == "startLive":
        session_id = event.get("sessionId") or "default-live-session"
        expires_at = start_live(
            ec2,
            context,
            session_id,
            LIVE_SESSION_TAG,
            LIVE_EXPIRES_TAG,
            schedule_action="stopLiveAfterDelay",
        )
        return {
            "statusCode": 200,
            "action": "startedLive",
            "maxRuntimeSeconds": LIVE_MAX_RUNTIME_SECONDS,
            "liveSessionId": session_id,
            "liveExpiresAt": str(expires_at),
            **describe_instance(ec2),
        }

    if isinstance(event, dict) and event.get("action") == "startLiveFace":
        session_id = event.get("sessionId") or "default-live-face-session"
        expires_at = start_live(
            ec2,
            context,
            session_id,
            LIVE_FACE_SESSION_TAG,
            LIVE_FACE_EXPIRES_TAG,
            schedule_action="stopLiveFaceAfterDelay",
        )
        return {
            "statusCode": 200,
            "action": "startedLiveFace",
            "maxRuntimeSeconds": LIVE_MAX_RUNTIME_SECONDS,
            "liveFaceSessionId": session_id,
            "liveFaceExpiresAt": str(expires_at),
            **describe_instance(ec2),
        }

    if isinstance(event, dict) and event.get("action") == "refreshLive":
        session_id = event.get("sessionId")
        if not session_id:
            return {"statusCode": 400, "errorMessage": "missing sessionId"}
        current = describe_instance(ec2)
        if current.get("liveSessionId") != session_id:
            return {
                "statusCode": 409,
                "errorMessage": "live session mismatch",
                **current,
            }
        expires_at = set_live_expiry(ec2, session_id, LIVE_SESSION_TAG, LIVE_EXPIRES_TAG)
        schedule_live_stop(context, session_id, action="stopLiveAfterDelay")
        return {
            "statusCode": 200,
            "action": "refreshedLive",
            "maxRuntimeSeconds": LIVE_MAX_RUNTIME_SECONDS,
            "liveSessionId": session_id,
            "liveExpiresAt": str(expires_at),
            **describe_instance(ec2),
        }

    if isinstance(event, dict) and event.get("action") == "refreshLiveFace":
        session_id = event.get("sessionId")
        if not session_id:
            return {"statusCode": 400, "errorMessage": "missing sessionId"}
        current = describe_instance(ec2)
        if current.get("liveFaceSessionId") != session_id:
            return {
                "statusCode": 409,
                "errorMessage": "live face session mismatch",
                **current,
            }
        expires_at = set_live_expiry(ec2, session_id, LIVE_FACE_SESSION_TAG, LIVE_FACE_EXPIRES_TAG)
        schedule_live_stop(context, session_id, action="stopLiveFaceAfterDelay")
        return {
            "statusCode": 200,
            "action": "refreshedLiveFace",
            "maxRuntimeSeconds": LIVE_MAX_RUNTIME_SECONDS,
            "liveFaceSessionId": session_id,
            "liveFaceExpiresAt": str(expires_at),
            **describe_instance(ec2),
        }

    if isinstance(event, dict) and event.get("action") == "stopLiveAfterDelay":
        session_id = event.get("sessionId")
        time.sleep(LIVE_MAX_RUNTIME_SECONDS)
        current = describe_instance(ec2)
        expires_at = int(current.get("liveExpiresAt") or "0")
        if current.get("liveSessionId") != session_id or int(time.time()) < expires_at:
            print(f"Skipped live stop for stale speaker session {session_id}; current={current}")
            return {"statusCode": 200, "action": "skippedStaleLiveStop"}
        clear_live_tags(ec2, LIVE_SESSION_TAG, LIVE_EXPIRES_TAG)
        current = describe_instance(ec2)
        if other_lease_active(current, "speaker"):
            print(f"Speaker lease expired for {session_id} but face lease still active; leaving EC2 running")
            return {"statusCode": 200, "action": "releasedKeepRunning", "service": "speaker", **current}
        stop_instance(ec2, f"live speaker session expired sessionId={session_id}")
        print(f"Stopped {INSTANCE_ID} after live speaker session {session_id} expired")
        return {"statusCode": 200, "action": "stoppedLive", "service": "speaker"}

    if isinstance(event, dict) and event.get("action") == "stopLiveFaceAfterDelay":
        session_id = event.get("sessionId")
        time.sleep(LIVE_MAX_RUNTIME_SECONDS)
        current = describe_instance(ec2)
        expires_at = int(current.get("liveFaceExpiresAt") or "0")
        if current.get("liveFaceSessionId") != session_id or int(time.time()) < expires_at:
            print(f"Skipped live stop for stale face session {session_id}; current={current}")
            return {"statusCode": 200, "action": "skippedStaleLiveStop"}
        clear_live_tags(ec2, LIVE_FACE_SESSION_TAG, LIVE_FACE_EXPIRES_TAG)
        current = describe_instance(ec2)
        if other_lease_active(current, "face"):
            print(f"Face lease expired for {session_id} but speaker lease still active; leaving EC2 running")
            return {"statusCode": 200, "action": "releasedKeepRunning", "service": "face", **current}
        stop_instance(ec2, f"live face session expired sessionId={session_id}")
        print(f"Stopped {INSTANCE_ID} after live face session {session_id} expired")
        return {"statusCode": 200, "action": "stoppedLive", "service": "face"}

    if isinstance(event, dict) and event.get("action") == "stopAfterDelay":
        time.sleep(MAX_RUNTIME_SECONDS)
        s3 = s3_client()
        spec = spec_from_stop_event(event)
        cycle = int(event.get("cycle") or 1)
        current = describe_instance(ec2)
        if spec and result_exists(s3, spec.get("bucket"), spec.get("resultKey")):
            put_job_status(s3, spec, "done", context, finishedAt=now_iso(), current=current)
            if other_lease_active(current, "diarization"):
                print(
                    f"Deferred diarization result watchdog stop jobId={spec.get('jobId')} because a live lease is active "
                    f"speaker={current.get('liveSessionId')} face={current.get('liveFaceSessionId')}"
                )
                return {
                    "statusCode": 200,
                    "action": "deferredAfterDiarization",
                    "jobId": spec.get("jobId"),
                    "cycle": cycle,
                    **current,
                }
            stop_instance(ec2, f"diarization result watchdog jobId={spec.get('jobId')}")
            print(f"Stopped {INSTANCE_ID} after diarization result appeared jobId={spec.get('jobId')} cycle={cycle}")
            return {"statusCode": 200, "action": "stoppedDone", "jobId": spec.get("jobId"), "cycle": cycle}
        if spec and cycle < MAX_DIARIZATION_WATCHDOG_CYCLES:
            put_job_status(
                s3,
                spec,
                "processing",
                context,
                current=current,
                watchdogCycle=cycle,
                maxWatchdogCycles=MAX_DIARIZATION_WATCHDOG_CYCLES,
            )
            lambda_client().invoke(
                FunctionName=context.invoked_function_arn,
                InvocationType="Event",
                Payload=stop_delay_payload(context, spec, cycle=cycle + 1),
            )
            print(
                f"Extended diarization watchdog jobId={spec.get('jobId')} "
                f"cycle={cycle}/{MAX_DIARIZATION_WATCHDOG_CYCLES}"
            )
            return {"statusCode": 200, "action": "extendedDiarization", "jobId": spec.get("jobId"), "cycle": cycle}
        if spec:
            put_job_status(
                s3,
                spec,
                "failed",
                context,
                failedAt=now_iso(),
                current=current,
                errorKind="ec2StoppedBeforeResult",
                errorMessage=f"Result key {spec.get('resultKey')} was still missing after {cycle} watchdog cycle(s).",
                watchdogCycle=cycle,
                maxWatchdogCycles=MAX_DIARIZATION_WATCHDOG_CYCLES,
            )
        if other_lease_active(current, "diarization"):
            print(
                f"Deferred exhausted diarization watchdog stop jobId={(spec or {}).get('jobId')} because a live lease is active "
                f"speaker={current.get('liveSessionId')} face={current.get('liveFaceSessionId')}"
            )
            return {
                "statusCode": 200,
                "action": "deferredAfterDiarization",
                "jobId": (spec or {}).get("jobId"),
                "cycle": cycle,
                **current,
            }
        stop_instance(ec2, f"diarization watchdog exhausted jobId={(spec or {}).get('jobId')}")
        print(f"Stopped {INSTANCE_ID} after {MAX_RUNTIME_SECONDS} seconds jobId={(spec or {}).get('jobId')} cycle={cycle}")
        return {"statusCode": 200, "action": "stopped", "jobId": (spec or {}).get("jobId"), "cycle": cycle}

    # S3-triggered diarization job path (default action). Boots EC2 and schedules
    # a fixed stop. This intentionally does not touch live-session tags so that
    # in-progress live face/speaker leases keep their own expiry timeline.
    s3_job = load_s3_job_context(event)
    s3 = s3_client()
    if s3_job:
        print(
            f"Diarization job trigger jobId={s3_job.get('jobId')} "
            f"audioKey={s3_job.get('audioKey')} resultKey={s3_job.get('resultKey')} "
            f"triggerKey={s3_job.get('triggerKey')}"
        )
        put_job_status(s3, s3_job, "ec2_starting", context)

    try:
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
        print(f"Started {INSTANCE_ID}; scheduling watchdog after {MAX_RUNTIME_SECONDS} seconds jobId={(s3_job or {}).get('jobId')}")
    except ec2.exceptions.ClientError as error:
        code = error.response["Error"]["Code"]
        if code == "IncorrectInstanceState":
            print(f"{INSTANCE_ID} already running; scheduling watchdog after {MAX_RUNTIME_SECONDS} seconds jobId={(s3_job or {}).get('jobId')}")
        else:
            raise
    if s3_job:
        put_job_status(s3, s3_job, "ec2_started", context, startedAt=now_iso(), current=describe_instance(ec2))

    invoker = boto3.client(
        "lambda",
        region_name=REGION,
        config=Config(
            connect_timeout=5,
            read_timeout=10,
            retries={"max_attempts": 1},
        ),
    )
    invoker.invoke(
        FunctionName=context.invoked_function_arn,
        InvocationType="Event",
        Payload=stop_delay_payload(context, s3_job, cycle=1),
    )
    return {
        "statusCode": 200,
        "action": "started",
        "maxRuntimeSeconds": MAX_RUNTIME_SECONDS,
        "jobId": (s3_job or {}).get("jobId"),
    }
