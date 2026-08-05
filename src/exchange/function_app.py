"""
Office 365 Management Activity API webhook receiver.

Behavior (driven entirely by app settings):
  1. Handshake — echoes the validation token/code so the subscription can be started.
  2. Notification — for each notification, pulls the content blob from the
     Management API and forwards every audit record to this app's Event Hub.

All configuration comes from environment variables / app settings:
  TENANT_ID, CLIENT_ID, CLIENT_SECRET        (Entra app — secret via Key Vault reference)
  CONTENT_TYPE                               (e.g. Audit.Exchange — informational)
  EVENT_HUB_NAME, EVENT_HUB_NAMESPACE_FQDN   (target Event Hub — auth via managed identity)
"""
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from urllib.parse import urlparse

import azure.functions as func
import requests
from azure.core.exceptions import HttpResponseError, ResourceExistsError, ResourceNotFoundError
from azure.eventhub import EventData, EventHubProducerClient
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobLeaseClient, BlobServiceClient

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

_MANAGEMENT_RESOURCE = "https://manage.office.com"
_MANAGEMENT_HOST = "manage.office.com"
_HTTP_TIMEOUT = 30
_CHECKPOINT_CONTAINER = "prism-ingestion-state"
_PROCESSED_CONTAINER = "prism-processed-content"
_RECONCILE_OVERLAP = timedelta(minutes=30)
_MAX_RECOVERY_AGE = timedelta(days=6, hours=23)


def _is_trusted_content_uri(content_uri: str) -> bool:
    """Only allow HTTPS content URIs served by the Management Activity API host."""
    try:
        parsed = urlparse(content_uri)
    except ValueError:
        return False
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and (
        host == _MANAGEMENT_HOST or host.endswith("." + _MANAGEMENT_HOST)
    )


def _get_management_token() -> str:
    tenant_id = os.environ["TENANT_ID"]
    resp = requests.post(
        f"https://login.microsoftonline.com/{tenant_id}/oauth2/token",
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["CLIENT_ID"],
            "client_secret": os.environ["CLIENT_SECRET"],
            "resource": _MANAGEMENT_RESOURCE,
        },
        timeout=_HTTP_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def _blob_service_client() -> BlobServiceClient:
    return BlobServiceClient(
        account_url=os.environ["AzureWebJobsStorage__blobServiceUri"],
        credential=DefaultAzureCredential(),
    )


def _ensure_state_containers(blob_service: BlobServiceClient) -> None:
    for container_name in (_CHECKPOINT_CONTAINER, _PROCESSED_CONTAINER):
        try:
            blob_service.create_container(container_name)
        except ResourceExistsError:
            pass


def _state_prefix() -> str:
    return os.environ["CONTENT_TYPE"].lower().replace(".", "-")


def _processed_blob(blob_service: BlobServiceClient, content_id: str):
    digest = sha256(content_id.encode("utf-8")).hexdigest()
    return blob_service.get_blob_client(
        _PROCESSED_CONTAINER,
        f"{_state_prefix()}/{digest}.json",
    )


def _load_watermark(blob_service: BlobServiceClient, now: datetime) -> datetime:
    checkpoint = blob_service.get_blob_client(
        _CHECKPOINT_CONTAINER,
        f"{_state_prefix()}/watermark.json",
    )
    try:
        payload = json.loads(checkpoint.download_blob().readall())
        watermark = datetime.fromisoformat(payload["watermark"].replace("Z", "+00:00"))
        return max(watermark, now - _MAX_RECOVERY_AGE)
    except (ResourceNotFoundError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return now - _MAX_RECOVERY_AGE


def _save_watermark(blob_service: BlobServiceClient, watermark: datetime) -> None:
    checkpoint = blob_service.get_blob_client(
        _CHECKPOINT_CONTAINER,
        f"{_state_prefix()}/watermark.json",
    )
    checkpoint.upload_blob(
        json.dumps({"watermark": watermark.isoformat()}),
        overwrite=True,
    )


def _forward_to_event_hub(records: list, renew_lease=None) -> int:
    if not records:
        return 0
    producer = EventHubProducerClient(
        fully_qualified_namespace=os.environ["EVENT_HUB_NAMESPACE_FQDN"],
        eventhub_name=os.environ["EVENT_HUB_NAME"],
        credential=DefaultAzureCredential(),
    )
    sent = 0
    try:
        batch = producer.create_batch()
        for record in records:
            data = EventData(json.dumps(record))
            try:
                batch.add(data)
            except ValueError:
                # The event did not fit the current batch. Flush a non-empty
                # batch and retry on a fresh one; if it still doesn't fit, fail
                # the content blob so reconciliation can retry and alert.
                if len(batch) > 0:
                    if renew_lease:
                        renew_lease()
                    producer.send_batch(batch)
                    sent += len(batch)
                    batch = producer.create_batch()
                try:
                    batch.add(data)
                except ValueError:
                    raise ValueError("Audit record is too large for an Event Hub batch")
        if len(batch) > 0:
            if renew_lease:
                renew_lease()
            producer.send_batch(batch)
            sent += len(batch)
    finally:
        producer.close()
    return sent


def _process_content(
    blob_service: BlobServiceClient,
    content_id: str,
    content_uri: str,
    token: str,
) -> int:
    marker = _processed_blob(blob_service, content_id)
    try:
        marker.upload_blob(
            json.dumps({"contentId": content_id, "status": "pending"}),
            overwrite=False,
        )
    except ResourceExistsError:
        pass

    lease = BlobLeaseClient(marker)
    try:
        lease.acquire(lease_duration=60)
    except HttpResponseError as exc:
        if exc.status_code == 409:
            return 0
        raise

    try:
        state = json.loads(marker.download_blob(lease=lease).readall())
        if state.get("status") == "complete":
            return 0
        if not _is_trusted_content_uri(content_uri):
            raise ValueError(f"Untrusted content URI: {content_uri}")

        response = requests.get(
            content_uri,
            headers={"Authorization": f"Bearer {token}"},
            timeout=_HTTP_TIMEOUT,
        )
        response.raise_for_status()
        lease.renew()
        records = response.json()
        if isinstance(records, dict):
            records = [records]
        if not isinstance(records, list):
            raise ValueError(f"Unexpected content response for {content_id}")

        sent = _forward_to_event_hub(records, lease.renew)
        marker.upload_blob(
            json.dumps(
                {
                    "contentId": content_id,
                    "status": "complete",
                    "processedAt": datetime.now(timezone.utc).isoformat(),
                }
            ),
            overwrite=True,
            lease=lease,
        )
        return sent
    finally:
        lease.release()


def _list_content(token: str, start: datetime, end: datetime):
    tenant_id = os.environ["TENANT_ID"]
    url = f"{_MANAGEMENT_RESOURCE}/api/v1.0/{tenant_id}/activity/feed/subscriptions/content"
    params = {
        "contentType": os.environ["CONTENT_TYPE"],
        "PublisherIdentifier": tenant_id,
        "startTime": start.isoformat().replace("+00:00", "Z"),
        "endTime": end.isoformat().replace("+00:00", "Z"),
    }
    headers = {"Authorization": f"Bearer {token}"}

    while url:
        if not _is_trusted_content_uri(url):
            raise ValueError(f"Untrusted pagination URI: {url}")
        response = requests.get(url, params=params, headers=headers, timeout=_HTTP_TIMEOUT)
        response.raise_for_status()
        content = response.json()
        if not isinstance(content, list):
            raise ValueError("Unexpected content-list response")
        yield from content
        url = response.headers.get("NextPageUri")
        params = None


def _verify_subscription(token: str) -> None:
    tenant_id = os.environ["TENANT_ID"]
    response = requests.get(
        f"{_MANAGEMENT_RESOURCE}/api/v1.0/{tenant_id}/activity/feed/subscriptions/list",
        params={"PublisherIdentifier": tenant_id},
        headers={"Authorization": f"Bearer {token}"},
        timeout=_HTTP_TIMEOUT,
    )
    response.raise_for_status()
    subscriptions = response.json()
    subscription = next(
        (
            item
            for item in subscriptions
            if item.get("contentType") == os.environ["CONTENT_TYPE"]
        ),
        None,
    )
    if not subscription:
        raise RuntimeError(f"No subscription found for {os.environ['CONTENT_TYPE']}")
    webhook = subscription.get("webhook") or {}
    if subscription.get("status") != "enabled" or webhook.get("status") != "enabled":
        raise RuntimeError(
            f"Unhealthy subscription for {os.environ['CONTENT_TYPE']}: "
            f"subscription={subscription.get('status')}, webhook={webhook.get('status')}"
        )


@app.route(route="webhook", methods=["GET", "POST"])
def webhook(req: func.HttpRequest) -> func.HttpResponse:
    # --- Validation handshake -------------------------------------------------
    # Microsoft Graph style: validationtoken query param.
    validation_token = req.params.get("validationtoken")
    if validation_token is not None:
        return func.HttpResponse(validation_token, status_code=200, mimetype="text/plain")

    # Office 365 Management API style: validationCode in the JSON body.
    try:
        body = req.get_json()
    except ValueError:
        body = None

    if isinstance(body, dict) and "validationCode" in body:
        code = body["validationCode"]
        return func.HttpResponse(
            code,
            status_code=200,
            mimetype="text/plain",
            headers={"Webhook-ValidationCode": code},
        )

    # --- Notification processing ---------------------------------------------
    notifications = body if isinstance(body, list) else []
    if not notifications:
        return func.HttpResponse("No notifications.", status_code=200)

    try:
        token = _get_management_token()
        blob_service = _blob_service_client()
        _ensure_state_containers(blob_service)
    except Exception:
        logging.exception("Failed to initialize webhook processing")
        return func.HttpResponse("Failed to initialize processing.", status_code=502)

    total_sent = 0
    failures = 0

    for notification in notifications:
        content_id = notification.get("contentId")
        content_uri = notification.get("contentUri")
        if not content_id or not content_uri:
            failures += 1
            continue
        try:
            total_sent += _process_content(blob_service, content_id, content_uri, token)
        except Exception:
            failures += 1
            logging.exception("Failed to process content blob: %s", content_id)

    logging.info(
        "Forwarded %d records to %s; %d content blobs failed",
        total_sent,
        os.environ.get("EVENT_HUB_NAME"),
        failures,
    )
    if failures:
        return func.HttpResponse(
            f"Processed {total_sent} records; {failures} content blobs failed.",
            status_code=502,
        )
    return func.HttpResponse(f"Processed {total_sent} records.", status_code=200)


@app.timer_trigger(
    schedule="0 */10 * * * *",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=True,
)
def reconcile_content(timer: func.TimerRequest) -> None:
    now = datetime.now(timezone.utc)
    if timer.past_due:
        logging.warning("Content reconciliation timer is running late")

    try:
        token = _get_management_token()
        _verify_subscription(token)
        blob_service = _blob_service_client()
        _ensure_state_containers(blob_service)
        cursor = max(
            _load_watermark(blob_service, now) - _RECONCILE_OVERLAP,
            now - _MAX_RECOVERY_AGE,
        )

        while cursor < now:
            window_end = min(cursor + timedelta(hours=24), now)
            failures = 0
            for content in _list_content(token, cursor, window_end):
                content_id = content.get("contentId")
                content_uri = content.get("contentUri")
                if not content_id or not content_uri:
                    failures += 1
                    continue
                try:
                    _process_content(blob_service, content_id, content_uri, token)
                except Exception:
                    failures += 1
                    logging.exception("Reconciliation failed for content blob: %s", content_id)

            if failures:
                raise RuntimeError(
                    f"Reconciliation window contains {failures} failed content blobs"
                )
            _save_watermark(blob_service, window_end)
            cursor = window_end
    except Exception:
        logging.exception("Content reconciliation failed")
        raise
