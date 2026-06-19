import time
import unittest
from unittest import mock

from botocore.exceptions import ClientError

import lambda_function


class FakeEC2:
    class Exceptions:
        ClientError = Exception

    exceptions = Exceptions()

    def __init__(self, tags=None):
        self.tags = tags or []
        self.stop_calls = 0
        self.deleted_tags = []

    def describe_instances(self, InstanceIds):
        return {
            "Reservations": [{
                "Instances": [{
                    "State": {"Name": "running"},
                    "PublicIpAddress": "203.0.113.1",
                    "PrivateIpAddress": "10.0.0.1",
                    "Tags": self.tags,
                }]
            }]
        }

    def stop_instances(self, InstanceIds):
        self.stop_calls += 1

    def delete_tags(self, Resources, Tags):
        self.deleted_tags.extend(tag["Key"] for tag in Tags)


class StopProtectedEC2(FakeEC2):
    def stop_instances(self, InstanceIds):
        self.stop_calls += 1
        raise ClientError(
            {
                "Error": {
                    "Code": "OperationNotPermitted",
                    "Message": "Modify its 'disableApiStop' instance attribute and try again.",
                }
            },
            "StopInstances",
        )


class FakeSSM:
    def __init__(self):
        self.commands = []

    def send_command(self, **kwargs):
        self.commands.append(kwargs)
        return {"Command": {"CommandId": "command-1"}}


class FakeS3:
    def __init__(self, result_exists):
        self.result_exists = result_exists
        self.puts = []

    def head_object(self, Bucket, Key):
        if not self.result_exists:
            raise ClientError({"Error": {"Code": "404"}}, "HeadObject")
        return {}

    def put_object(self, **kwargs):
        self.puts.append(kwargs)
        return {}


class Context:
    invoked_function_arn = "arn:aws:lambda:us-west-1:123:function:test"


class CompletionShutdownTests(unittest.TestCase):
    def test_stops_immediately_without_live_leases(self):
        ec2 = FakeEC2()
        with mock.patch.object(lambda_function.boto3, "client", return_value=ec2):
            response = lambda_function.lambda_handler(
                {"action": "stopAfterDiarizationComplete", "jobId": "job-1"},
                Context(),
            )

        self.assertEqual(response["action"], "stoppedAfterDiarization")
        self.assertEqual(ec2.stop_calls, 1)
        self.assertIn(lambda_function.LIVE_SESSION_TAG, ec2.deleted_tags)
        self.assertIn(lambda_function.LIVE_FACE_SESSION_TAG, ec2.deleted_tags)

    def test_defers_shutdown_while_face_lease_is_active(self):
        ec2 = FakeEC2(tags=[
            {"Key": lambda_function.LIVE_FACE_SESSION_TAG, "Value": "face-session"},
            {"Key": lambda_function.LIVE_FACE_EXPIRES_TAG, "Value": str(int(time.time()) + 300)},
        ])
        with mock.patch.object(lambda_function.boto3, "client", return_value=ec2):
            response = lambda_function.lambda_handler(
                {"action": "stopAfterDiarizationComplete", "jobId": "job-2"},
                Context(),
            )

        self.assertEqual(response["action"], "deferredAfterDiarization")
        self.assertEqual(ec2.stop_calls, 0)

    def test_uses_in_instance_shutdown_when_stop_protection_blocks_ec2_api(self):
        ec2 = StopProtectedEC2()
        ssm = FakeSSM()

        def client(service_name, **kwargs):
            return ec2 if service_name == "ec2" else ssm

        with mock.patch.object(lambda_function.boto3, "client", side_effect=client):
            response = lambda_function.lambda_handler(
                {"action": "stopAfterDiarizationComplete", "jobId": "job-3"},
                Context(),
            )

        self.assertEqual(response["action"], "stoppedAfterDiarization")
        self.assertEqual(response["shutdownMethod"], "ssmShutdown")
        self.assertEqual(len(ssm.commands), 1)
        self.assertEqual(ssm.commands[0]["InstanceIds"], [lambda_function.INSTANCE_ID])
        self.assertEqual(
            ssm.commands[0]["Parameters"],
            {"commands": ["sudo shutdown -h now"]},
        )


class WatchdogShutdownTests(unittest.TestCase):
    def stop_event(self, cycle=1):
        return {
            "action": "stopAfterDelay",
            "cycle": cycle,
            "bucket": "test-bucket",
            "jobId": "job-watchdog",
            "resultKey": "results/job-watchdog/result.json",
            "statusKey": "jobs/job-watchdog/status.json",
        }

    def test_result_watchdog_defers_while_face_lease_is_active(self):
        ec2 = FakeEC2(tags=[
            {"Key": lambda_function.LIVE_FACE_SESSION_TAG, "Value": "face-session"},
            {"Key": lambda_function.LIVE_FACE_EXPIRES_TAG, "Value": str(int(time.time()) + 300)},
        ])
        s3 = FakeS3(result_exists=True)

        with (
            mock.patch.object(lambda_function.boto3, "client", return_value=ec2),
            mock.patch.object(lambda_function, "s3_client", return_value=s3),
            mock.patch.object(lambda_function.time, "sleep"),
        ):
            response = lambda_function.lambda_handler(self.stop_event(), Context())

        self.assertEqual(response["action"], "deferredAfterDiarization")
        self.assertEqual(ec2.stop_calls, 0)
        self.assertEqual(len(s3.puts), 1)

    def test_exhausted_watchdog_defers_while_speaker_lease_is_active(self):
        ec2 = FakeEC2(tags=[
            {"Key": lambda_function.LIVE_SESSION_TAG, "Value": "speaker-session"},
            {"Key": lambda_function.LIVE_EXPIRES_TAG, "Value": str(int(time.time()) + 300)},
        ])
        s3 = FakeS3(result_exists=False)

        with (
            mock.patch.object(lambda_function.boto3, "client", return_value=ec2),
            mock.patch.object(lambda_function, "s3_client", return_value=s3),
            mock.patch.object(lambda_function.time, "sleep"),
        ):
            response = lambda_function.lambda_handler(
                self.stop_event(cycle=lambda_function.MAX_DIARIZATION_WATCHDOG_CYCLES),
                Context(),
            )

        self.assertEqual(response["action"], "deferredAfterDiarization")
        self.assertEqual(ec2.stop_calls, 0)
        self.assertEqual(len(s3.puts), 1)


if __name__ == "__main__":
    unittest.main()
