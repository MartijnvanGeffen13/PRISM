# PRISM — Deployment guide

This guide covers everything needed to provision a PRISM instance: prerequisites,
the one-time Entra app registration, running `azd up`, selecting audit workloads,
starting the audit subscriptions and the Stream Analytics job, and the full
configuration reference.

For the overall design see [solution-proposal.md](solution-proposal.md), and for
cost estimates see [cost-proposal.md](cost-proposal.md). For Power BI reporting,
see the [Power BI reporting](../README.md#power-bi-reporting) section in the
README.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) with Bicep
- Python 3.11+
- An Azure subscription with permission to create resource groups and role assignments
- A **shared Entra app registration** (see below)

### Entra app registration (manual, one-time)

This template does **not** create the app registration. Before deploying, create
one app registration in your tenant and grant admin consent for:

- **Office 365 Management API**: `ActivityFeed.Read`, `ActivityFeed.ReadDlp` (application)
- **Microsoft Graph**: `User.Read.All` (application)

Record the **tenant id**, **client id**, and a **client secret**.

## Deploy

```pwsh
# 1. Authenticate
azd auth login

# 2. Create an environment (this becomes the resource group name suffix)
azd env new prism

# 3. Provide configuration (see .env.sample for the full list)
azd env set AZURE_LOCATION       westeurope
azd env set ENTRA_TENANT_ID      <your-tenant-guid>
azd env set ENTRA_CLIENT_ID      <your-app-client-guid>
azd env set ENTRA_CLIENT_SECRET  <your-app-secret>      # never committed

# Optional: allow your current public IP through resource firewalls to deploy
azd env set DEPLOYER_IP_ADDRESS  <your-public-ip>

# Optional: allow report-author / Power BI Desktop public IPs inbound to the
# Data Lake through its Network Security Perimeter (JSON array; /32 assumed when
# no CIDR is given). Empty by default. Applied by the azd postprovision hook
# after provisioning, so re-run `azd provision` (or `azd up`) after changing it.
azd env set DATA_LAKE_ALLOWED_IPS '["203.0.113.10/32"]'

# 4. Provision infrastructure and deploy the functions
azd up
```

After deployment, run the webhook bootstrap scripts (`createwebhooks/`) once to
start the Office 365 Management API subscriptions (see below).

### Choose which audit workloads to deploy (`enabledWorkloads`)

The `enabledWorkloads` array in [`infra/main.parameters.json`](../infra/main.parameters.json)
controls which audit APIs are provisioned. Valid values: `exchange`,
`sharepoint`, `dlp`, `general`, `azuread` (all five are enabled by default).
Each entry provisions a **complete, isolated pipeline** — Function App, Event
Hub, runtime storage + private endpoints, App Insights, role assignments — plus
one input/output on the **shared** Stream Analytics job. The `entrausers`
snapshot function is **always** deployed and is not part of this list.

To deploy a subset, edit the array before `azd up` / `azd provision`, e.g. only
Exchange and DLP:

```json
"enabledWorkloads": { "value": ["exchange", "dlp"] }
```

> **Removing an entry does not delete already-created resources.** `azd provision`
> runs an **incremental** deployment, so pipelines you drop from the array stay in
> place and keep accruing cost. To actually remove them, delete those resources
> explicitly (portal/CLI) or tear the environment down with `azd down`. See
> [cost-proposal.md](cost-proposal.md) §5 for the per-workload cost impact.

## Start the audit subscriptions (`createwebhooks/`)

The Office 365 Management API only pushes audit content once a subscription is
started for each content type. Run the scripts in `createwebhooks/` **once**
after `azd up` (and again if a subscription is ever stopped). Run only the
scripts for the workloads you enabled in `enabledWorkloads`:

| Script | Content type | Webhook env var |
|--------|--------------|-----------------|
| `CreateWebhookSubscription1.ps1` | `Audit.Exchange` | `EXCHANGE_WEBHOOK_URL` |
| `CreateWebhookSubscription2.ps1` | `Audit.SharePoint` | `SHAREPOINT_WEBHOOK_URL` |
| `CreateWebhookSubscription3.ps1` | `DLP.All` | `DLP_WEBHOOK_URL` |
| `CreateWebhookSubscription4.ps1` | `Audit.General` | `GENERAL_WEBHOOK_URL` |
| `CreateWebhookSubscription5.ps1` | `Audit.AzureActiveDirectory` | `AZUREAD_WEBHOOK_URL` |

The scripts read **all** values from environment variables — nothing is hard-coded.
Get each Function App's webhook URL (including its `?code=` function key) from the
Azure portal (Function App → Functions → `webhook` → Get function URL) or from your
deployment outputs.

```pwsh
# Same app registration values used for the deployment
$env:PURVIEW_TENANT_ID     = "<your-tenant-guid>"
$env:PURVIEW_CLIENT_ID     = "<your-app-client-guid>"
$env:PURVIEW_CLIENT_SECRET = "<your-app-secret>"      # never committed

# Each Function App's full webhook URL, including the ?code=<function-key>
$env:EXCHANGE_WEBHOOK_URL   = "https://<exchange-func>.azurewebsites.net/api/webhook?code=<key>"
$env:SHAREPOINT_WEBHOOK_URL = "https://<sharepoint-func>.azurewebsites.net/api/webhook?code=<key>"
$env:DLP_WEBHOOK_URL        = "https://<dlp-func>.azurewebsites.net/api/webhook?code=<key>"
$env:GENERAL_WEBHOOK_URL    = "https://<general-func>.azurewebsites.net/api/webhook?code=<key>"
$env:AZUREAD_WEBHOOK_URL    = "https://<azuread-func>.azurewebsites.net/api/webhook?code=<key>"

# Run each once — a 200 with a "status: enabled" subscription confirms success
./createwebhooks/CreateWebhookSubscription1.ps1
./createwebhooks/CreateWebhookSubscription2.ps1
./createwebhooks/CreateWebhookSubscription3.ps1
./createwebhooks/CreateWebhookSubscription4.ps1
./createwebhooks/CreateWebhookSubscription5.ps1
```

> The Function App keys in `*_WEBHOOK_URL` are secrets — set them only as
> environment variables for the current session; never commit them.

## Start the Stream Analytics job

The **single, shared** Stream Analytics job (`asa-prism-<token>`) is created in a
**Stopped** state — ARM/Bicep (and `azd up`) provision it but **do not start it
automatically**. Start it **once** after deployment so it begins draining every
enabled Event Hub (one input/output per workload) into the Data Lake. This is a
one-time action; the job stays running across future `azd up` / `azd deploy` runs.

**Option A — Azure portal (GUI):** open the Stream Analytics job `asa-prism-…` →
**Overview** → **Start** → set **Job output start time** to **Now** → **Start**.

**Option B — Azure CLI:** start every Stream Analytics job in the resource group
(requires the `stream-analytics` extension — `az extension add -n stream-analytics`
if prompted):

```pwsh
$rg = "rg-PRISM"   # your resource group (rg-<azd env name>)
foreach ($job in (az stream-analytics job list -g $rg --query "[].name" -o tsv)) {
  Write-Host "Starting $job ..."
  az stream-analytics job start -g $rg --job-name $job --output-start-mode JobStartTime
}
```

> Check state at any time:
> `az stream-analytics job list -g rg-PRISM --query "[].{name:name,state:jobState}" -o table`

## Configuration reference

| Setting | Required | Description |
|---------|----------|-------------|
| `AZURE_LOCATION` | Yes | Azure region for all resources. |
| `ENTRA_TENANT_ID` | Yes | Tenant id of the shared app registration. |
| `ENTRA_CLIENT_ID` | Yes | Client id of the shared app registration. |
| `ENTRA_CLIENT_SECRET` | Yes | App client secret (deploy time only). |
| `enabledWorkloads` | No | Bicep param (array in `infra/main.parameters.json`) selecting which audit APIs deploy: `exchange`, `sharepoint`, `dlp`, `general`, `azuread`. All five by default. |
| `DEPLOYER_IP_ADDRESS` | No | Public IP allowed through firewalls to deploy from outside the VNet. Also added to the Data Lake perimeter inbound rule. |
| `DATA_LAKE_ALLOWED_IPS` | No | JSON array of report-author / gateway public IPs allowed inbound to the Data Lake via its Network Security Perimeter. Applied by the postprovision hook (`scripts/set-datalake-nsp-ip-rule.ps1`). Empty by default. |
| `dataLakeUserPrincipalIds` | No | Bicep param — Entra object ids granted Data Lake read. Empty by default. |
