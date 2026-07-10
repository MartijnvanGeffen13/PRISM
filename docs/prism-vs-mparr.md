# PRISM vs. MPARR — solution comparison

A side-by-side comparison of **PRISM** (this project) and Microsoft's community
[**MPARR** (Microsoft Purview Advanced Rich Reports) Collector](https://github.com/microsoft/Microsoft-Purview-Advanced-Rich-Reports-MPARR-Collector).
Both ingest Microsoft 365 / Purview audit activity for Power BI reporting — but they
take fundamentally different architectural approaches.

> MPARR details are based on its public GitHub repository (100% PowerShell, MIT
> "public template", 6 contributors, no formal releases). PRISM figures come from
> [solution-proposal.md](solution-proposal.md) and [cost-proposal.md](cost-proposal.md).
> Use this as a decision aid, not a benchmark.

## At a glance

| Dimension | **PRISM** ✅ | MPARR |
|-----------|--------------|-------|
| **Architecture** | Event-driven, **serverless** Azure pipeline: webhook → Function → Event Hub → Stream Analytics → Data Lake | Scheduled **PowerShell scripts** pulling the Management API on a host/runner |
| **Data store** | **Azure Data Lake (ADLS Gen2)** — open NDJSON you own | **Log Analytics** workspace (often shared with Sentinel) |
| **Deployment** | **One command** — `azd up` provisions everything from IaC (Bicep) | Manual: edit `laconfig.json`, register app + certificate, set up host & scheduled tasks (PDF guide) |
| **Compute to run/maintain** | **None** — fully serverless (Flex Consumption Functions + managed Stream Analytics) | You provide & patch a **host** (VM / server / Automation) to run the scripts |
| **Secrets model** | **Managed identity** everywhere; one secret in **Key Vault** | Certificate / secret stored on the runner host |
| **Network security** | **VNet + private endpoints + Network Security Perimeter** on the lake | Depends on the host; data governed by Log Analytics RBAC |
| **Scaling** | Elastic, near-real-time, **per-workload isolated** pipelines | Bigger host / more frequent runs; single Log Analytics sink |
| **Long-term retention cost** | **Object-storage prices** (~$0.02 / GB-month) | **Log Analytics ingestion + retention** (~$2.90 / GB ingested) |
| **Extensibility** | Open JSON → Power BI, **Fabric, Synapse, Databricks, any SIEM** | Coupled to Log Analytics schema + PowerShell |
| **Delivery model** | **Deploy-your-own-instance** IaC template, parameterized | Community sample scripts you assemble & operate |

## Where PRISM wins

### 💰 Cost — pay for storage, not ingestion

MPARR lands every audit record in **Log Analytics**, billed at **~$2.90/GB ingested**
plus retention. Audit data is high-volume and grows forever, so cost scales **linearly
and painfully** with volume *and* history.

PRISM lands the same data as **NDJSON in a Data Lake at ~$0.02/GB-month** — roughly
**~100× cheaper per GB for long-term retention**. PRISM's monthly bill (~$383 at
1M records/day, all five workloads) is dominated by **fixed serverless
infrastructure**, not by data volume — it's **nearly identical at 100K/day or 5M/day**,
and you can trim it further by disabling workloads (`enabledWorkloads`). For multi-year
compliance retention, storing raw JSON in a lake is dramatically cheaper than keeping it
hot in Log Analytics.

### 🚀 Implementation — one command, not a runbook

- **PRISM:** `azd up`. Infrastructure-as-Code (Bicep) provisions the **entire stack**
  into a single resource group — reproducible, version-controlled, and parameterized.
  Choose workloads with a single array (`enabledWorkloads`).
- **MPARR:** follow a PDF guide — create an app registration and certificate, edit
  `laconfig.json`, stand up a host, wire up scheduled tasks, and create Log Analytics
  custom tables by hand. No IaC; each environment is assembled manually.

### 🛠️ Maintenance — nothing to patch

- **PRISM:** **fully serverless.** No VMs or runners to patch, no PowerShell modules to
  keep current, no scheduled-task babysitting. **Managed identity** secures every
  Azure-to-Azure hop (secretless); only the app client secret lives in **Key Vault**.
  Built-in **Application Insights + Log Analytics** monitoring. Redeploy or tear down
  cleanly with `azd`.
- **MPARR:** you **own the compute** — OS patching, PowerShell/module upgrades,
  certificate rotation, and monitoring/retrying failed script runs are all on you.

### 🧩 Flexibility — open data, any tool

- **PRISM:** data lands as **open NDJSON in your own lake**, directly consumable by
  **Power BI, Microsoft Fabric, Synapse, Databricks, or any SIEM** — no schema lock-in.
  Each workload is an **isolated pipeline** you can enable/disable independently.
- **MPARR:** reporting is tied to the **Log Analytics schema** and PowerShell collectors;
  extending means more scripting against that model.

### 🔒 Security — enterprise network isolation by default

PRISM ships with **VNet integration, private endpoints, disabled local/shared-key auth,
and a Network Security Perimeter** guarding the Data Lake's public access — inbound is
denied by default and opened only to explicit report-author IPs. Secretless managed
identity is the default, not an add-on.

## Where MPARR may still fit

To stay honest: MPARR is a **mature, well-known** community solution with a **large
library of prebuilt Power BI reports and workbooks** and extra collectors (RMS/MIP
scanner, Entra attributes, etc.), and it integrates naturally with **Microsoft Sentinel**
when you're already centralizing security data in Log Analytics. If you want ready-made
dashboards out of the box, already run everything in Log Analytics/Sentinel, and are
comfortable operating PowerShell on a host, MPARR is a reasonable choice.

**PRISM is the better fit when you want** a hands-off, serverless, IaC-deployed pipeline;
**low-cost, long-term retention** of raw audit data you fully own; **secretless,
network-isolated security**; and the freedom to report from **any** analytics tool — not
just Log Analytics.

## Summary

| | **PRISM** | MPARR |
|---|-----------|-------|
| Get running | `azd up` (minutes, repeatable) | Manual multi-step install |
| Run it | Serverless — nothing to patch | Operate a host + scheduled scripts |
| Store audit data | Cheap, open data lake (yours) | Log Analytics (ingestion-priced) |
| Long-term retention | ~$0.02/GB-month | ~$2.90/GB ingested |
| Consume from | Power BI, Fabric, Synapse, any SIEM | Log Analytics / Power BI |
| Security | MI + Key Vault + private endpoints + NSP | Host-based cert/secret |
| Best for | Modern, low-maintenance, cost-efficient, tool-agnostic reporting | Turnkey prebuilt reports on Log Analytics/Sentinel |

> **Bottom line:** PRISM turns Microsoft 365 audit reporting into a **modern,
> serverless, deploy-your-own-instance** solution — cheaper to retain, near-zero to
> maintain, secure by default, and open to any analytics tool.
