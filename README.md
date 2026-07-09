## Let me know in the discussions if you like this project , if you have improvement ideas, or just say hello if you deployed PRISM in your environment and what you experience is with the tool


# PRISM — Purview Reporting & Insights System for Metadata

PRISM ingests Microsoft 365 audit data (Exchange, SharePoint, DLP, General, and
Azure Active Directory) and a weekly
Entra users snapshot into an Azure Data Lake for Power BI reporting. It is
deployed as a **self-contained, deploy-your-own-instance** template: every
organization provisions its own isolated stack in its own subscription.

> This is **not** a multi-tenant SaaS. Each deployment serves a single tenant.

## Architecture

Azure Function Apps land data into per-workload Event Hubs, which are drained by
Stream Analytics jobs into a single Data Lake (Gen2) whose public access is
governed by a **Network Security Perimeter (NSP)**. Which audit
workloads deploy is controlled by the `enabledWorkloads` parameter
(`infra/main.parameters.json`) — each entry provisions its own Function App,
Event Hub, Stream Analytics job, and role assignments. Secrets are stored in Key
Vault and read via managed identity. See
[docs/solution-proposal.md](docs/solution-proposal.md) for the full design and
[docs/cost-proposal.md](docs/cost-proposal.md) for cost estimates.

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

The `enabledWorkloads` array in [`infra/main.parameters.json`](infra/main.parameters.json)
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
> [docs/cost-proposal.md](docs/cost-proposal.md) §5 for the per-workload cost impact.

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

## Power BI reporting

The `PBI-Mquerys/` folder contains the Power Query (M) definitions that build the
reporting model over the Data Lake. Each file is **one query**; the queries
reference each other **by name**, so names must match the file names exactly.

### 1. Prerequisites

- **Power BI Desktop** (latest).
- The report author's identity (or the gateway) has **Storage Blob Data Reader**
  (or Contributor) on the Data Lake.
- The author's public IP is allowed inbound through the Data Lake's Network
  Security Perimeter via `DATA_LAKE_ALLOWED_IPS` (applied by the postprovision hook).
- Your deployment's storage account name (the `DATA_LAKE_ACCOUNT_NAME` output),
  e.g. `dlprismab12cd`.

### 2. Option A — use the PRISM template (recommended)

If a `PRISM.pbit` template is published with the release, this is the fastest path:

1. Double-click `PRISM.pbit` (or **File → Import → Power BI template**).
2. When prompted, enter the **`DataLakeAccountName`** parameter (storage account
   name only — no `https://`, no suffix).
3. Sign in to the storage source with an **Organizational account** when asked.
4. Make sure your public IP is allowed inbound through the Data Lake's Network
   Security Perimeter (`DATA_LAKE_ALLOWED_IPS`). See deploy variables.
5. **Refresh**. All queries, load settings, and relationships come pre-configured.

> See [Build the `.pbit` template](#5-build-the-pbit-template-maintainers) for how a
> maintainer produces this file once from the queries below.

### 3. Option B — import the M queries manually

1. **Create the parameters first.** In **Home → Transform data** (Power Query
   Editor), **New Source → Blank Query → Advanced Editor**, paste the contents of
   `PBI-Mquerys/DataLakeAccountName`, and rename the query to exactly
   `DataLakeAccountName`. Power BI recognises the `IsParameterQuery` annotation and
   treats it as a parameter. Set its **Current Value** to your storage account name.
   (Alternatively use **Manage Parameters → New**, Type = Text.) Do the same with
   `PBI-Mquerys/LoadDays` (rename to exactly `LoadDays`, Type = Number) — it sets the
   rolling window of audit history to load, in days (default **360**). Every audit
   `*Staging` query reads only day-partition folders newer than today minus `LoadDays`,
   so refreshes scan a bounded window instead of the whole lake. (`UsersStaging` is a
   single overwritten snapshot and ignores it.)
2. **Add each remaining query.** For every other file in `PBI-Mquerys/`:
   **New Source → Blank Query → Advanced Editor**, paste the file's contents, and
   **rename the query to match the file name exactly** (e.g. `DlpStaging`,
   `DlpEvent`). Exact names are required because queries reference one another.
3. **Set Enable load** per the table below (right-click a query → **Enable load**).
4. **Close & Apply.** Sign in with an **Organizational account** if prompted for the
   Data Lake source.
5. Create the **relationships** in Model view (section 4).

#### Enable-load settings

| Query / group | Enable load | Why |
|---------------|-------------|-----|
| `DataLakeAccountName` | — (parameter) | Connection parameter, not a table. |
| `LoadDays` | — (parameter) | Rolling window (days) of history to load; default 360. Not a table. |
| `fnExpandAllRecords` | **OFF** | Helper function. |
| `ExchangeStaging`, `SharePointStaging`, `DlpStaging`, `GeneralStaging`, `AzureAdStaging`, `UsersStaging` | **OFF** | Shared base queries; parsed once, consumed by children. |
| `ExchangeEvent`, `ExchangeParameters`, `ExchangeOperationProperties` | **ON** | Exchange fact + children. |
| `SharePointEvent`, `SharePointModifiedProperties` | **ON** | SharePoint fact + child. |
| `DlpEvent`, `DlpEndpointSit`, `DlpExchangeRecipients`, `DlpPolicy`, `DlpRule`, `DlpSensitiveInfo` | **ON** | DLP fact + children. |
| `GeneralEvent`, `GeneralDLPAction` | **ON** | Audit.General fact + child (`GeneralDLPAction` parses the JSON-encoded `NewValue` DLP-action detail). |
| `AzureAdEvent`, `AzureAdExtendedProperties`, `AzureAdModifiedProperties`, `AzureAdActor`, `AzureAdTarget` | **ON** | Audit.AzureActiveDirectory fact + children. |
| `UsersEvent` | **ON** | Entra users fact. |

### 4. Relationships

In **Model view**, create these relationships (This is a example, you might need other mapping based on you reporting needs.!!). All are **one-to-many**
(1 → \*) with **single** cross-filter direction, from the parent (the `1` side)
to the child, and **active**.

| Parent (1) · key | Child (\*) · key | Cardinality |
|------------------|------------------|-------------|
| `ExchangeEvent[EventId]` | `ExchangeParameters[EventId]` | 1 → \* |
| `ExchangeEvent[EventId]` | `ExchangeOperationProperties[EventId]` | 1 → \* |
| `SharePointEvent[EventId]` | `SharePointModifiedProperties[EventId]` | 1 → \* |
| `DlpEvent[EventId]` | `DlpEndpointSit[EventId]` | 1 → \* |
| `DlpEvent[EventId]` | `DlpExchangeRecipients[EventId]` | 1 → \* |
| `DlpEvent[EventId]` | `DlpPolicy[EventId]` | 1 → \* |
| `DlpPolicy[PolicyKey]` | `DlpRule[PolicyKey]` | 1 → \* |
| `DlpRule[RuleKey]` | `DlpSensitiveInfo[RuleKey]` | 1 → \* |
| `GeneralEvent[EventId]` | `GeneralDLPAction[EventId]` | 1 → \* |
| `AzureAdEvent[EventId]` | `AzureAdExtendedProperties[EventId]` | 1 → \* |
| `AzureAdEvent[EventId]` | `AzureAdModifiedProperties[EventId]` | 1 → \* |
| `AzureAdEvent[EventId]` | `AzureAdActor[EventId]` | 1 → \* |
| `AzureAdEvent[EventId]` | `AzureAdTarget[EventId]` | 1 → \* |
| `UsersEvent[userPrincipalName]` | `ExchangeEvent[UserId]` | 1 → \* |
| `UsersEvent[userPrincipalName]` | `SharePointEvent[UserId]` | 1 → \* |
| `UsersEvent[userPrincipalName]` | `DlpEvent[UserId]` | 1 → \* |
| `UsersEvent[userPrincipalName]` | `GeneralEvent[UserId]` | 1 → \* |
| `UsersEvent[userPrincipalName]` | `AzureAdEvent[UserId]` | 1 → \* |

`UsersEvent` is a shared **user dimension**: its `userPrincipalName` maps
one-to-many to each workload fact's `UserId`, so a single user filter slices
Exchange, SharePoint, DLP, General, and Azure AD together. The workload facts
(`ExchangeEvent`, `SharePointEvent`, `DlpEvent`, `GeneralEvent`, `AzureAdEvent`)
remain independent of one another (no direct cross-workload relationship) — they
are linked only through the shared `UsersEvent` dimension. Only build the
relationships for the workloads you actually enabled in `enabledWorkloads`.

```mermaid
erDiagram
    ExchangeEvent ||--o{ ExchangeParameters : "EventId"
    ExchangeEvent ||--o{ ExchangeOperationProperties : "EventId"
    SharePointEvent ||--o{ SharePointModifiedProperties : "EventId"
    DlpEvent ||--o{ DlpEndpointSit : "EventId"
    DlpEvent ||--o{ DlpExchangeRecipients : "EventId"
    DlpEvent ||--o{ DlpPolicy : "EventId"
    DlpPolicy ||--o{ DlpRule : "PolicyKey"
    DlpRule ||--o{ DlpSensitiveInfo : "RuleKey"
    GeneralEvent ||--o{ GeneralDLPAction : "EventId"
    AzureAdEvent ||--o{ AzureAdExtendedProperties : "EventId"
    AzureAdEvent ||--o{ AzureAdModifiedProperties : "EventId"
    AzureAdEvent ||--o{ AzureAdActor : "EventId"
    AzureAdEvent ||--o{ AzureAdTarget : "EventId"
    UsersEvent ||--o{ ExchangeEvent : "userPrincipalName → UserId"
    UsersEvent ||--o{ SharePointEvent : "userPrincipalName → UserId"
    UsersEvent ||--o{ DlpEvent : "userPrincipalName → UserId"
    UsersEvent ||--o{ GeneralEvent : "userPrincipalName → UserId"
    UsersEvent ||--o{ AzureAdEvent : "userPrincipalName → UserId"
```


### 5. (Optional) Incremental refresh — faster refreshes (Power BI Premium / PPU / Fabric)

By default every refresh re-reads the **entire** data lake, which gets slower as
history grows ("waiting for datalake storage"). Incremental refresh makes Power BI
re-read only the **most recent** daily partitions and leave older data untouched,
so refresh time stays flat. It requires **Power BI Premium, Premium-Per-User (PPU),
or Fabric** and the dataset **published to the service**.

**Prerequisite (query side).** The `*Staging` queries must filter their files on two
datetime parameters named exactly `RangeStart` and `RangeEnd`, derived from the
`yyyy/MM/dd` folder path (this pairs with the daily ASA output). This is **not wired
in the shipped queries yet** — ask a maintainer to enable it (or see the staging
pattern in the project notes) before configuring the policy below. Power BI's
incremental refresh only works when the parameters are consumed by a folded/pruning
filter, so history outside `[RangeStart, RangeEnd)` is never downloaded.

**Configure the policy (per fact table):**

1. Publish the report to a **Premium/PPU/Fabric** workspace (incremental refresh is
   defined in Desktop but only executes in the service).
2. In **Power BI Desktop**, confirm the `RangeStart` and `RangeEnd` parameters exist
   (**Home → Transform data → Manage Parameters**), both **Date/Time**.
3. In the **Data** pane, **right-click a fact table** (e.g. `GeneralEvent`,
   `ExchangeEvent`, `DlpEvent`, `SharePointEvent`, `AzureAdEvent`, `UsersEvent`) →
   **Incremental refresh**.
4. Toggle **Incrementally refresh this table** to **On**.
5. Set **Archive data starting** *N* years/months before refresh date (how much
   history to keep, e.g. **Store rows from the past 2 years**).
6. Set **Incrementally refresh data starting** *M* days before refresh date (the
   window actually re-read each run, e.g. **Refresh rows from the past 7 days**).
   Smaller = faster refresh.
7. (Optional) Enable **Detect data changes** or **Only refresh complete days** if you
   want finer control; leave **Get the latest data in real time (DirectQuery)** off
   for this import model.
8. **Apply**, then **Publish** to the Premium/PPU/Fabric workspace and run a refresh.
   The **first** service refresh is a full load (it builds the partitions); every
   refresh after only re-reads the last *M* days.

**Repeat steps 3–8 for each enabled fact table.** The per-workload child tables
(`GeneralDLPAction`, `Dlp*`, `AzureAd*`, …) read the same filtered staging, so they
inherit the pruning automatically — you do **not** configure a policy on them.

> **Already shipped:** the `*Staging` queries implement a manual rolling window via the
> `LoadDays` parameter (default **360** days), so even on plain Pro/Desktop each refresh
> only scans the last `LoadDays` of day-partition folders (a big speedup; the report then
> holds a rolling window of history rather than all of it). Incremental refresh (above)
> is the Premium/PPU/Fabric upgrade that additionally skips re-reading days already loaded.


## Security notes

- **Never commit secrets.** `.env`, `local.settings.json`, and `.azure/**` are
  git-ignored. Provide the client secret only via `azd env set`.
- Secrets live in **Key Vault**; Function Apps read them via **managed identity**.
- The Data Lake's public network access is **secured by a Network Security
  Perimeter** (`publicNetworkAccess: 'SecuredByPerimeter'`). Inbound public
  access is denied by default; the perimeter allows only the report-author /
  gateway IPs from `DATA_LAKE_ALLOWED_IPS` (empty by default — never open it
  broadly) plus in-subscription Azure services (the Stream Analytics job). The
  report-author IP rule is applied by the **azd postprovision hook**
  ([`scripts/set-datalake-nsp-ip-rule.ps1`](scripts/set-datalake-nsp-ip-rule.ps1)),
  because the NSP provider cannot write an IP rule and a subscription rule in the
  same ARM deployment. The `entrausers` function reaches the lake over its
  **private endpoint**, which the perimeter always permits without a rule.
- No tenant-specific defaults are baked into the templates; all identity values
  are supplied at deploy time.

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
| `dataLakeUserPrincipalIds` | No | Bicep param — Entra object ids granted Data Lake read. Empty by default. |
