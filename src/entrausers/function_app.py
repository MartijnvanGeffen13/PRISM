"""
Weekly Microsoft Entra user snapshot.

Runs on a timer, pages every user from Microsoft Graph, and OVERWRITES a single
blob in the data lake so the file always holds the current, de-duplicated set of
users (no history).

Configuration (environment variables / app settings):
  TENANT_ID, CLIENT_ID, CLIENT_SECRET   (Entra app — secret via Key Vault reference)
  DATALAKE_BLOB_ENDPOINT                (storage blob service URI, e.g. https://acct.blob.core.windows.net/)
  DATALAKE_CONTAINER                    (e.g. reference)
  DATALAKE_BLOB                         (e.g. entra/users.json)
  GRAPH_USER_SELECT                     ($select fields, comma separated)
  SNAPSHOT_SCHEDULE                     (NCRONTAB, default weekly Mon 02:00 UTC)
"""
import json
import logging
import os
from datetime import datetime, timezone

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()

_GRAPH_RESOURCE = "https://graph.microsoft.com"
_HTTP_TIMEOUT = 60
_DEFAULT_SELECT = (
    "id,displayName,givenName,surname,userPrincipalName,mail,mailNickname,imAddresses,jobTitle,department,companyName,employeeId,employeeType,employeeHireDate,officeLocation,streetAddress,city,state,postalCode,country,usageLocation,preferredLanguage,accountEnabled,userType,createdDateTime"
)
"""
_DEFAULT_SELECT = (
    "id,displayName,givenName,surname,userPrincipalName,mail,mailNickname,otherMails,proxyAddresses,imAddresses,jobTitle,department,companyName,employeeId,employeeType,employeeHireDate,officeLocation,streetAddress,city,state,postalCode,country,usageLocation,businessPhones,mobilePhone,faxNumber,preferredLanguage,accountEnabled,userType,createdDateTime,creationType,externalUserState,externalUserStateChangeDateTime,ageGroup,consentProvidedForMinor,legalAgeGroupClassification,passwordPolicies,lastPasswordChangeDateTime,showInAddressList,assignedLicenses,assignedPlans,provisionedPlans,identities,onPremisesSyncEnabled,onPremisesImmutableId,onPremisesSamAccountName,onPremisesUserPrincipalName,onPremisesDomainName,onPremisesDistinguishedName,onPremisesSecurityIdentifier,onPremisesLastSyncDateTime,deletedDateTime"
)
"""
_SCHEDULE = os.environ.get("SNAPSHOT_SCHEDULE", "0 */30 * * * *")


def _get_graph_token() -> str:
    tenant_id = os.environ["TENANT_ID"]
    resp = requests.post(
        f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token",
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["CLIENT_ID"],
            "client_secret": os.environ["CLIENT_SECRET"],
            "scope": f"{_GRAPH_RESOURCE}/.default",
        },
        timeout=_HTTP_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def _fetch_all_users(token: str) -> list:
    select = os.environ.get("GRAPH_USER_SELECT", _DEFAULT_SELECT)
    headers = {"Authorization": f"Bearer {token}"}
    users: list = []
    url = f"{_GRAPH_RESOURCE}/v1.0/users?$select={select}&$top=999"

    while url:
        resp = requests.get(url, headers=headers, timeout=_HTTP_TIMEOUT)
        resp.raise_for_status()
        payload = resp.json()
        users.extend(payload.get("value", []))
        url = payload.get("@odata.nextLink")

    return users


@app.timer_trigger(schedule=_SCHEDULE, arg_name="timer", run_on_startup=True, use_monitor=True)
def snapshot_entra_users(timer: func.TimerRequest) -> None:
    logging.info("Starting Entra user snapshot")

    token = _get_graph_token()
    users = _fetch_all_users(token)

    snapshot = {
        "generatedUtc": datetime.now(timezone.utc).isoformat(),
        "count": len(users),
        "value": users,
    }

    blob_service = BlobServiceClient(
        account_url=os.environ["DATALAKE_BLOB_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    blob_client = blob_service.get_blob_client(
        container=os.environ["DATALAKE_CONTAINER"],
        blob=os.environ["DATALAKE_BLOB"],
    )
    blob_client.upload_blob(
        json.dumps(snapshot, ensure_ascii=False).encode("utf-8"),
        overwrite=True,
    )

    logging.info("Wrote %d users to %s/%s", len(users),
                 os.environ["DATALAKE_CONTAINER"], os.environ["DATALAKE_BLOB"])
