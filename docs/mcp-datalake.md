# Adding MCP capabilities to the PRISM Data Lake

This guide explains **two ways** to make the PRISM audit Data Lake queryable by AI
assistants through the **Model Context Protocol (MCP)**, so users can ask natural
questions like *"how many DLP hits did finance trigger last week?"* instead of writing
queries.

- **[Option A — Azure MCP Server](#option-a--azure-mcp-server)** — point Microsoft's
  ready-made Azure MCP Server at the PRISM storage account. **No code.** File/blob-level
  access to the NDJSON in the lake. Best for quick, ad-hoc exploration.
- **[Option C — Microsoft Fabric Data Agent](#option-c--microsoft-fabric-data-agent-report-model)** —
  build a **governed, natural-language Q&A agent** over a Fabric lakehouse/semantic model
  fed by the PRISM lake. Best for production, business-user reporting, and Purview-governed
  access. (Option B, a custom MCP server, is covered separately.)

> **How they differ:** Option A exposes **raw storage operations** (list/read blobs) — the
> LLM reads files and reasons over them, which is great for small slices but weak for large
> history. Option C exposes a **query engine** (NL→SQL/DAX/KQL) with governance, row-level
> security, and Purview policy enforcement — far better for scale and compliance.

For where the data lives, see [solution-proposal.md](solution-proposal.md) (§5 Data Lake
layout). Relevant paths in the account (the `DATA_LAKE_ACCOUNT_NAME` output):

```
container: auditlogs/
  exchange-json/    sharepoint-json/    dlp-json/
  general-json/     azuread-json/
container: reference/
  entra/users.json
```

---

## Shared prerequisites (both options)

1. **The storage account name** — the `DATA_LAKE_ACCOUNT_NAME` deployment output
   (e.g. `dlprismab12cd`).
2. **An Entra identity with read access.** PRISM disables shared-key auth, so access is
   **RBAC + Entra ID only**. Grant the consumer (your user, a service principal, or a
   managed identity) **`Storage Blob Data Reader`** on the Data Lake — never a write role
   for reporting:

   ```pwsh
   $rg  = "rg-PRISM"
   $acct = "<DATA_LAKE_ACCOUNT_NAME>"
   $scope = az storage account show -g $rg -n $acct --query id -o tsv
   az role assignment create `
     --assignee "<user-or-sp-object-id>" `
     --role "Storage Blob Data Reader" `
     --scope $scope
   ```

3. **Network access through the Network Security Perimeter (NSP).** The lake's public
   access is `SecuredByPerimeter` — inbound is denied by default. Choose one:
   - **From a workstation / on-prem:** add the caller's **public IP** to
     `DATA_LAKE_ALLOWED_IPS` and re-run `azd provision` (the postprovision hook
     [`scripts/set-datalake-nsp-ip-rule.ps1`](../scripts/set-datalake-nsp-ip-rule.ps1)
     writes the NSP inbound rule). See the
     [Deployment guide → Configuration reference](deploy.md#configuration-reference).
   - **From inside Azure (VNet):** run the MCP host in the PRISM VNet and reach the lake
     over its **private endpoint** — the perimeter always permits private-endpoint traffic
     without an IP rule. This is the preferred, IP-free path for Option C (Fabric).

> **Least privilege:** keep every MCP identity **read-only** (`Storage Blob Data Reader`),
> scope it to the Data Lake account only, and prefer managed identity over secrets.

---

## Option A — Azure MCP Server

The **[Azure MCP Server](https://aka.ms/azmcp)** (now maintained at
[`microsoft/mcp`](https://github.com/microsoft/mcp/tree/main/servers/Azure.Mcp.Server))
ships Storage/Data Lake tools that let an MCP-capable client **list containers, list
blob/Data Lake paths, and read blob content**. You point it at the PRISM account and the
assistant browses and reads the NDJSON directly.

**What you get:** zero-code, Microsoft-maintained, works in VS Code / Copilot, Claude
Desktop, Cursor, and others. **Trade-off:** it's *file-level* — the LLM reads whole files
and filters afterward, so it's ideal for targeted slices (a day, one workload) but not for
scanning the full lake.

### Step 1 — Pick how to run it

You don't have to pre-install anything; the client launches it on demand. Runtimes:

| Runtime | Launch command |
|---------|----------------|
| **Node (npm)** | `npx -y @azure/mcp@latest server start` |
| **.NET** | `dnx Azure.Mcp` (NuGet package `Azure.Mcp`) |
| **Python (PyPI)** | package `msmcp-azure` |
| **Docker** | run the published container image (see the server README) |

Node (`npx`) is the simplest for a workstation.

### Step 2 — Sign in (authentication)

The server uses **Azure Identity (`DefaultAzureCredential`)** — it reuses whatever
credential is already available on the machine. The easiest is the Azure CLI:

```pwsh
az login                       # sign in as the identity that holds Storage Blob Data Reader
az account set --subscription "<prism-subscription-id>"
```

Make sure that identity has the RBAC role and NSP access from
[Shared prerequisites](#shared-prerequisites-both-options).

### Step 3 — Register the server with your MCP client

**Visual Studio Code (Copilot).** Create/edit `.vscode/mcp.json` in your workspace (or add
to user settings):

```jsonc
{
  "servers": {
    "azure": {
      "command": "npx",
      "args": ["-y", "@azure/mcp@latest", "server", "start"]
    }
  }
}
```

Then open the Copilot Chat **Agent** mode → **Tools** and enable the `azure` server. VS Code
starts it and discovers its tools.

**Claude Desktop.** Edit `claude_desktop_config.json`
(`%APPDATA%\Claude\` on Windows) and restart Claude:

```jsonc
{
  "mcpServers": {
    "azure": {
      "command": "npx",
      "args": ["-y", "@azure/mcp@latest", "server", "start"]
    }
  }
}
```

> To reduce tool sprawl you can start the server in a storage-focused mode (namespace
> filtering) so only the storage tools are exposed — see the server README's namespace
> options.

### Step 4 — Consume it (example prompts)

With the server connected and you signed in, ask the assistant things like:

- *"Using the azure tools, list the blob containers in storage account **`<DATA_LAKE_ACCOUNT_NAME>`**."*
- *"List the paths under `auditlogs/dlp-json/` for 2026/07/09."*
- *"Read `reference/entra/users.json` and tell me how many users are in the marketing department."*
- *"Open today's `auditlogs/exchange-json/` files and summarize the top 5 operations."*

The assistant calls the storage tools, reads the NDJSON, and answers. Point it at a
**specific day/workload path** to keep reads small and fast.

### Step 5 — Harden

- Assign only **`Storage Blob Data Reader`** to the MCP identity (read-only).
- Keep NSP inbound tight — only the exact author IPs in `DATA_LAKE_ALLOWED_IPS`.
- Prefer a dedicated service principal or managed identity for shared/hosted use rather
  than a personal `az login`.
- Treat model output as untrusted; don't let the assistant write back to the lake (no write
  role is granted, so it physically can't).

### Option A limitations

- File/blob granularity only — **no SQL-style filtering or aggregation server-side**; large
  time ranges mean the LLM downloads many files.
- No semantic model, relationships, or measures — the assistant sees raw JSON fields.
- Best for exploration and spot checks, not business-user self-service reporting.

---

## Option C — Microsoft Fabric Data Agent (report-model)

A **[Fabric data agent](https://learn.microsoft.com/fabric/data-science/concept-data-agent)**
turns your PRISM reporting model into a **governed, natural-language Q&A agent**. It
generates **read-only** NL→SQL / NL→DAX / NL→KQL queries, respects **Microsoft Purview**
policies and Power BI **row-/column-level security**, and can be consumed from Fabric chat,
**Microsoft 365 Copilot**, **Copilot Studio**, **Azure AI Foundry**, Teams, or any external
agent/MCP orchestrator.

**What you get:** production-grade, business-user-friendly, governed access at scale —
exactly the "report-model MCP" surface. **Trade-off:** requires **Fabric/Power BI Premium
capacity** and a modeling step (files must be exposed as **tables**, not raw JSON).

### Step 0 — Prerequisites

- A **paid Fabric capacity (F2 or higher)** *or* **Power BI Premium P1+** with Fabric
  enabled, and a workspace on that capacity.
- Tenant settings for Fabric data agents / Copilot enabled (and cross-geo AI processing if
  your capacity and data regions differ — data agents can't query across regions).
- **Read access** to the data you'll expose.

### Step 1 — Get the PRISM data into Fabric

Two supported approaches — pick one:

**1a. OneLake shortcut to the PRISM ADLS Gen2 (recommended, no data copy).**
In a Fabric **Lakehouse**, create a **Shortcut → ADLS Gen2**, pointing at the PRISM
`auditlogs` container. Authenticate with an identity that has `Storage Blob Data Reader` and
NSP access (run through the **private endpoint** path so no public IP is needed). The lake
data now appears in OneLake without duplication.

> **Fabric data agents query tables, not files.** After shortcutting, load the NDJSON into
> **Delta tables** — e.g. a notebook `spark.read.json("Files/auditlogs/dlp-json/**")` →
> `.write.saveAsTable("dlp_event")`, one table per workload — or build a **semantic model**
> over them. Raw `.json` files are not directly queryable by the agent.

**1b. Publish the existing PRISM Power BI semantic model.**
PRISM already ships a Power BI model (the [`PBI-Mquerys/`](../PBI-Mquerys) queries — see the
[Power BI reporting guide](powerbi.md)). Publish that report/dataset to your **Premium/Fabric**
workspace. The published **semantic model** (with its relationships and measures) becomes a
first-class Fabric data-agent data source — this reuses all your existing modeling.

### Step 2 — Model the data (tables / semantic model)

- If you loaded Delta tables (1a): give them clean names (`exchange_event`, `dlp_event`,
  `users`, …) and add relationships if you build a semantic model over them.
- If you published the PRISM model (1b): it already has the fact/child tables and the
  `UsersEvent` user dimension relationships described in the
  [Power BI reporting guide](powerbi.md#4-relationships) — no extra modeling needed.

### Step 3 — Create the Fabric data agent

1. In the Fabric workspace, **New → Data agent** and name it (e.g. `PRISM Audit Agent`).
2. **Add data source(s)** — select your PRISM lakehouse and/or the published semantic model
   (up to five sources per agent).
3. **Choose tables** — add only the relevant fact/dimension tables (e.g. `dlp_event`,
   `exchange_event`, `users`). Fewer, well-named tables → better answers.

### Step 4 — Add instructions and example queries

Improve accuracy by giving the agent context:

- **Instructions**, e.g. *"This model contains Microsoft 365 audit events. `UserId` joins to
  the `users` dimension on `userPrincipalName`. Route DLP questions to `dlp_event`, mailbox
  activity to `exchange_event`. Always apply a date filter when the user names a period."*
- **Example query pairs** (question → SQL/DAX/KQL) for common asks, e.g. *"top 10 users by
  DLP hits last 7 days."* (Note: example pairs aren't supported for Power BI semantic-model
  sources — use instructions there.)

### Step 5 — Publish

Use **Publish** to make the agent available. Optionally wire **Git integration** and
**deployment pipelines** to promote dev → test → prod, and use built-in **diagnostics** to
review query generation.

### Step 6 — Connect and consume

The published agent can be consumed several ways:

- **Fabric chat UI** — ask questions directly in the workspace.
- **Microsoft 365 Copilot** — surface it inside Teams/M365 apps; Purview policies still apply.
- **Copilot Studio / Azure AI Foundry / external multi-agent runtimes** — invoke the data
  agent as a **governed, read-only tool** in a larger agentic workflow (this is the MCP-style
  integration point — an external orchestrator calls the Fabric data agent as a tool).
- **Programmatically** — call the published data-agent endpoint from your own app/SDK to add
  natural-language analytics to a portal.

Example questions end users can ask:

- *"How many DLP incidents did the Finance department trigger last month?"*
- *"Show SharePoint file downloads by country this week."*
- *"Which users had the most Azure AD sign-in changes in Q2?"*

### Governance with Microsoft Purview

Because the source is Microsoft 365 audit data, governance matters. Fabric data agents
**enforce read-only access**, honor **Purview DLP and access-restriction policies** on the
underlying warehouse/lakehouse, apply **RLS/CLS** on semantic models, and log agent
prompts/responses for **Purview Audit and eDiscovery**. Configure these before sharing the
agent broadly.

### Option C limitations

- Requires **Fabric F2+ / Power BI Premium** capacity (cost).
- Queries **tables, not raw files** — you must ingest/expose the NDJSON as tables or a
  semantic model (Step 1).
- Responses are **conversational**, capped around **25 rows × 25 columns** — great for
  insights, not bulk export.
- **Read-only**; English-only today; the agent's LLM isn't user-selectable; data source and
  agent capacities must be in the **same region**.

---

## Which option should I choose?

| | **Option A — Azure MCP Server** | **Option C — Fabric Data Agent** |
|---|---|---|
| Effort | Minutes, no code | Modeling + capacity setup |
| Cost | Free server; pay only storage egress | Fabric/Premium capacity |
| Access model | Raw list/read blobs | Governed NL→SQL/DAX/KQL |
| Scale | Small slices (day/workload) | Full history, aggregations |
| Governance | RBAC + NSP only | + Purview policies, RLS/CLS, audit |
| Audience | Developers / analysts | Business users, M365 Copilot |
| Consume from | VS Code, Claude, Cursor, etc. | Fabric, M365 Copilot, Copilot Studio, Foundry, external agents |

**Rule of thumb:** use **Option A** for quick, developer-driven exploration of the lake; use
**Option C** when you want governed, business-user, natural-language reporting at scale — and
combine it with Purview for a compliant audit-analytics experience.

## Security checklist (both options)

- [ ] Consumer identity holds **`Storage Blob Data Reader`** only (no write roles).
- [ ] NSP inbound limited to exact author IPs, or access via **private endpoint**.
- [ ] Prefer **managed identity / service principal** over personal logins for shared hosts.
- [ ] Never expose storage keys or the Entra client secret to the MCP client.
- [ ] For Fabric: enable **Purview** governance and appropriate **RLS/CLS** before sharing.
- [ ] Review agent/MCP **audit logs** periodically for unexpected query patterns.
