import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from azure.core.exceptions import HttpResponseError, ResourceExistsError


MODULE_PATH = Path(__file__).parents[1] / "src" / "exchange" / "function_app.py"
SPEC = importlib.util.spec_from_file_location("exchange_function_app", MODULE_PATH)
receiver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receiver)


class AuditReceiverTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(
            os.environ,
            {
                "CONTENT_TYPE": "Audit.Exchange",
                "EVENT_HUB_NAME": "eh-exchange",
            },
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)

        self.marker = MagicMock()
        self.blob_service = MagicMock()
        self.blob_service.get_blob_client.return_value = self.marker
        self.lease = MagicMock()
        self.lease_class = patch.object(receiver, "BlobLeaseClient", return_value=self.lease)
        self.lease_class.start()
        self.addCleanup(self.lease_class.stop)

    def test_completed_content_is_not_forwarded_again(self):
        self.marker.upload_blob.side_effect = ResourceExistsError("exists")
        self.marker.download_blob.return_value.readall.return_value = json.dumps(
            {"status": "complete"}
        ).encode()

        with patch.object(receiver.requests, "get") as get, patch.object(
            receiver, "_forward_to_event_hub"
        ) as forward:
            sent = receiver._process_content(
                self.blob_service,
                "content-1",
                "https://manage.office.com/content/1",
                "token",
            )

        self.assertEqual(0, sent)
        get.assert_not_called()
        forward.assert_not_called()
        self.lease.release.assert_called_once()

    def test_active_lease_defers_concurrent_processing(self):
        conflict = HttpResponseError("leased")
        conflict.status_code = 409
        self.lease.acquire.side_effect = conflict

        sent = receiver._process_content(
            self.blob_service,
            "content-1",
            "https://manage.office.com/content/1",
            "token",
        )

        self.assertEqual(0, sent)
        self.lease.release.assert_not_called()

    def test_success_marks_content_complete(self):
        self.marker.download_blob.return_value.readall.return_value = json.dumps(
            {"status": "pending"}
        ).encode()
        response = MagicMock()
        response.json.return_value = [{"Id": "event-1"}]

        with patch.object(receiver.requests, "get", return_value=response), patch.object(
            receiver, "_forward_to_event_hub", return_value=1
        ) as forward:
            sent = receiver._process_content(
                self.blob_service,
                "content-1",
                "https://manage.office.com/content/1",
                "token",
            )

        self.assertEqual(1, sent)
        forward.assert_called_once_with([{"Id": "event-1"}], self.lease.renew)
        completed = json.loads(self.marker.upload_blob.call_args_list[-1].args[0])
        self.assertEqual("complete", completed["status"])
        self.lease.release.assert_called_once()

    def test_processing_failure_releases_lease_for_retry(self):
        self.marker.download_blob.return_value.readall.return_value = json.dumps(
            {"status": "pending"}
        ).encode()

        with patch.object(receiver.requests, "get", side_effect=RuntimeError("failed")):
            with self.assertRaisesRegex(RuntimeError, "failed"):
                receiver._process_content(
                    self.blob_service,
                    "content-1",
                    "https://manage.office.com/content/1",
                    "token",
                )

        self.lease.release.assert_called_once()


if __name__ == "__main__":
    unittest.main()
