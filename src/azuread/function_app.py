"""
Office 365 Management Activity API webhook receiver.

Behavior (driven entirely by app settings):
  1. Handshake — echoes the validation token/code so the subscription can be started.
  2. Notification — for each notification, pulls the content blob from the
     Management API and forwards every audit record to this app's Event Hub.

All configuration comes from environment variables / app settings:
  TENANT_ID, CLIENT_ID, CLIENT_SECRET        (Entra app — secret via Key Vault reference)
  CONTENT_TYPE                               (e.g. Audit.AzureActiveDirectory — informational)
  EVENT_HUB_NAME, EVENT_HUB_NAMESPACE_FQDN   (target Event Hub — auth via managed identity)
"""
import json
import logging
import os

import azure.functions as func
import requests
from azure.eventhub import EventData, EventHubProducerClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

_MANAGEMENT_RESOURCE = "https://manage.office.com"
_HTTP_TIMEOUT = 30


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


def _forward_to_event_hub(records: list) -> int:
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
                # Batch full — flush and start a new one.
                producer.send_batch(batch)
                sent += len(batch)
                batch = producer.create_batch()
                batch.add(data)
        if len(batch) > 0:
            producer.send_batch(batch)
            sent += len(batch)
    finally:
        producer.close()
    return sent


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
    except requests.RequestException as exc:
        logging.exception("Failed to acquire management token")
        return func.HttpResponse(f"Auth error: {exc}", status_code=502)

    headers = {"Authorization": f"Bearer {token}"}
    total_sent = 0

    for notification in notifications:
        content_uri = notification.get("contentUri")
        if not content_uri:
            continue
        try:
            content_resp = requests.get(content_uri, headers=headers, timeout=_HTTP_TIMEOUT)
            content_resp.raise_for_status()
            records = content_resp.json()
        except (requests.RequestException, ValueError):
            logging.exception("Failed to pull content blob: %s", content_uri)
            continue

        if isinstance(records, dict):
            records = [records]
        total_sent += _forward_to_event_hub(records)

    logging.info("Forwarded %d records to %s", total_sent, os.environ.get("EVENT_HUB_NAME"))
    return func.HttpResponse(f"Processed {total_sent} records.", status_code=200)
