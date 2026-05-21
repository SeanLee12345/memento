import boto3
import time
from botocore.config import Config

INSTANCE_ID = "i-0c400af918e775f20"
REGION = "us-west-1"
MAX_RUNTIME_SECONDS = 180


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
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        print(f"Stopped {INSTANCE_ID} from explicit stopNow action")
        return {"statusCode": 200, "action": "stopped"}

    if isinstance(event, dict) and event.get("action") == "stopAfterDelay":
        time.sleep(MAX_RUNTIME_SECONDS)
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        print(f"Stopped {INSTANCE_ID} after {MAX_RUNTIME_SECONDS} seconds")
        return {"statusCode": 200, "action": "stopped"}

    try:
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
        print(f"Started {INSTANCE_ID}; scheduling stop after {MAX_RUNTIME_SECONDS} seconds")
    except ec2.exceptions.ClientError as error:
        code = error.response["Error"]["Code"]
        if code == "IncorrectInstanceState":
            print(f"{INSTANCE_ID} already running; scheduling stop after {MAX_RUNTIME_SECONDS} seconds")
        else:
            raise

    lambda_client = boto3.client(
        "lambda",
        region_name=REGION,
        config=Config(
            connect_timeout=5,
            read_timeout=10,
            retries={"max_attempts": 1},
        ),
    )
    lambda_client.invoke(
        FunctionName=context.invoked_function_arn,
        InvocationType="Event",
        Payload=b'{"action":"stopAfterDelay"}',
    )
    return {
        "statusCode": 200,
        "action": "started",
        "maxRuntimeSeconds": MAX_RUNTIME_SECONDS,
    }
