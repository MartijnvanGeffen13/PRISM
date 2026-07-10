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
| **Landing cost per GB** | **~$0 one-time** — write JSON to the lake | **~$2.90 / GB** Log Analytics ingestion (one-time, per GB) |
| **Long-term retention cost** | **Object-storage prices** (~$0.02 / GB-month, ~$0.01 Cool) | **Log Analytics retention** (~$0.10 / GB-month beyond the free 31 days) |
| **Est. secure monthly cost (month 1)** | **~$383 @1M/day · ~$390 @5M/day — flat** | **~$178 @1M/day · ~$658 @5M/day** (plain LA; higher with Sentinel), **grows** with retention (see [Cost](#-cost--detailed-side-by-side-same-1m--5m-recordsday-basis)) |
| **Extensibility** | Open JSON → Power BI, **Fabric, Synapse, Databricks, any SIEM** | Coupled to Log Analytics schema + PowerShell |
| **Delivery model** | **Deploy-your-own-instance** IaC template, parameterized | Community sample scripts you assemble & operate |

## Where PRISM wins

### 💰 Cost — flat vs. volume-and-retention-driven

MPARR lands every audit record in **Log Analytics**, billed at **~$2.90/GB ingested**
(a one-time, per-GB charge) plus **~$0.10/GB-month retention** beyond the free 31 days.
Audit data is high-volume and kept for years, so **both** the landing cost *and* the
retention cost scale **linearly** with data volume and history.

PRISM lands the same data as **NDJSON in a Data Lake** — **~$0 to land** and
**~$0.02/GB-month to retain** (~$0.01 in Cool). Per GB, PRISM is **~145× cheaper to
land** and **~5–10× cheaper to retain**. Crucially, PRISM's monthly bill is dominated
by **fixed serverless infrastructure**, so it is **flat (~$383) regardless of volume or
retention** — nearly identical at 100K/day or 5M/day — whereas MPARR's bill **grows
without bound** with both. See the full side-by-side below.

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

## 💰 Cost — detailed side-by-side (same 1M & 5M records/day basis)

Both figures use the **same workload**: **1,000,000 audit records/day ≈ ~41 GB/month**
(measured ~1.48 KB/record — see [cost-proposal.md](cost-proposal.md) §0), plus a
high-volume **5,000,000 records/day ≈ ~205 GB/month** scenario. West Europe, pay-as-you-go
list prices. To be fair, **MPARR is costed with the same security posture as PRISM** — a
private, network-isolated deployment (VNet, private endpoints, Network Security
Perimeter, Key Vault, private DNS) — **plus the host it needs to run the scheduled
PowerShell collectors**, which PRISM does not require.

### Secure MPARR deployment — resources costed

| # | Resource | Why it's needed | Billing |
|---|----------|-----------------|---------|
| 1 | **Collector host VM** (B2s, Linux + PowerShell 7, 24/7) | Runs the MPARR collector scripts on scheduled tasks/cron | Per hour |
| 2 | **VM OS disk** (Standard SSD E10, 128 GB) | Host OS + scripts + working files | Per month |
| 3 | **Log Analytics workspace** | MPARR's data sink (custom tables) | ~$2.90/GB ingested + retention |
| 3a | **Microsoft Sentinel** (*if the workspace is Sentinel-enabled*) | MPARR is commonly paired with Sentinel; adds analysis on the same data | **+~$2.46/GB** analyzed |
| 4 | **Azure Monitor Private Link Scope (AMPLS) + private endpoint** | Private, no-public-internet ingestion into Log Analytics | PE/hour + data |
| 5 | **Private endpoint — Key Vault** | Private access to the app cert/secret | PE/hour |
| 6 | **Private endpoint — host storage** | Boot diagnostics / staging over private link | PE/hour |
| 7 | **Private DNS zones (~6)** | `monitor`/`ods`/`oms`/`agentsvc`/`blob` + Key Vault name resolution | Per zone/month |
| 8 | **Key Vault** | Store the Entra app certificate/secret MPARR authenticates with | Per 10k ops |
| 9 | **Network Security Perimeter** | Guard public access to the workspace/Key Vault (same as PRISM) | **No charge** |
| 10 | **VNet + subnets** | Network isolation for host + private endpoints | **Free** |
| 11 | **Azure Bastion (Basic)** — *optional* | Patch/operate the host with **no public IP** | Per hour (see note) |

> MPARR needs **no Event Hubs and no Stream Analytics** (it pushes straight to Log
> Analytics), which is where it saves vs. PRISM — but it **adds a host to patch and
> operate**, and swaps cheap lake storage for **ingestion-priced** Log Analytics.

### MPARR monthly estimate @ 1M records/day (West Europe, PAYG)

| Component | Calculation | Month 1 |
|-----------|-------------|--------:|
| **Log Analytics ingestion** | (41 − 5 free) GB × $2.90 | **$104** |
| **Collector host VM (B2s, 24/7)** | 730 h × ~$0.05 | **$36** |
| **VM OS disk (E10, 128 GB)** | fixed | **$10** |
| **Private endpoints (3: AMPLS, Key Vault, storage)** | 3 × $0.01 × 730 | **$22** |
| **Private DNS zones (6)** | 6 × $0.50 | **$3** |
| **Host storage (boot-diag/staging)** | small footprint | **$2** |
| **Key Vault** | cert/secret operations | **$1** |
| **Log Analytics retention** | month 1 within free 31 days | **$0** |
| **Network Security Perimeter / VNet** | — | **$0** |
| **Total (secure, month 1)** | | **≈ $178** |
| *Azure Bastion (Basic), optional secure admin* | *730 × ~$0.19* | *+$140* |

> **The $178 assumes a *plain* Log Analytics workspace (ingestion only).** MPARR is
> frequently pointed at a **Sentinel-enabled** workspace (the doc's own "often shared
> with Sentinel" scenario). **Enabling Microsoft Sentinel adds a per-GB analysis charge
> of ~$2.46/GB on top of the ~$2.90/GB Log Analytics ingestion** — roughly **$5.36/GB
> combined**. At ~41 GB/month that adds **~$89/month** (36 GB × $2.46), taking secure
> MPARR to **~$267/month in month 1** — and Sentinel retention beyond its free 90 days
> is still billed at **~$0.10/GB-month**. (Sentinel does raise the free retention window
> from 31 to **90 days**, and commitment tiers can lower the effective rate at scale.)
> **~$0.10/GB-month**. At ~41 GB/month added, the retention line climbs to **~$45/mo
> after 1 year**, **~$143/mo after 3 years**, and **~$241/mo after 5 years** — and never
> stops growing. PRISM stores the same history in the lake at **~$0.02/GB-month**
> (~$0.01 in Cool via lifecycle), so its retention line after 5 years is only **~$50/mo**.

### MPARR monthly estimate @ 5M records/day (~205 GB/month)

| Component | Calculation | Month 1 |
|-----------|-------------|--------:|
| **Log Analytics ingestion** | (205 − 5 free) GB × $2.90 | **$580** |
| *+ Microsoft Sentinel analysis (if enabled)* | *200 GB × $2.46* | *+$492* |
| **Collector host VM (B2s, 24/7)** | 730 h × ~$0.05 | **$36** |
| **VM OS disk (E10) + host storage** | fixed | **$12** |
| **Private endpoints (3)** | 3 × $0.01 × 730 | **$22** |
| **Private DNS zones (6) + Key Vault** | fixed | **$4** |
| **Log Analytics retention** | month 1 within free window | **$0** |
| **Total — plain Log Analytics** | | **≈ $658** |
| **Total — with Microsoft Sentinel** | | **≈ $1,150** |

> **PRISM at 5M/day stays ~$390** (fixed-infrastructure dominated; ~58 events/s is still
> a fraction of one Event Hubs TU / Stream Analytics SU). So at 5M/day PRISM is already
> **~$270 cheaper (plain LA)** to **~$760 cheaper (Sentinel)** in **month 1**, before
> retention even begins to compound.

### PRISM vs. MPARR — total monthly cost over time @ 1M records/day

| Horizon | **PRISM** (flat) | MPARR (secure, no Bastion) | Difference |
|---------|-----------------:|---------------------------:|-----------|
| **Month 1** | **~$383** | ~$178 (plain LA) / ~$267 (Sentinel) | MPARR **~$205 / ~$116 cheaper** |
| **Year 1 (avg)** | **~$383** | ~$200 / ~$290 | MPARR ~$183 / ~$93 cheaper |
| **Year 3** | **~$383** | ~$321 / ~$410 | MPARR ~$62 cheaper / **PRISM ~$27 cheaper** |
| **Year 5** | **~$383** | ~$419 / ~$508 | **PRISM ~$36 / ~$125 cheaper** |
| **Year 7** | **~$383** | ~$500+ / ~$590+ | **PRISM ~$120+ / ~$210+ cheaper** |

> Two MPARR columns: **plain Log Analytics** vs. a **Sentinel-enabled** workspace
> (+~$2.46/GB analysis). With Sentinel, MPARR crosses **above** PRISM by ~Year 3, and
> **adding Azure Bastion (+$140/mo)** pushes it above PRISM from Month 1. PRISM has **no
> host to reach**, so it needs no Bastion, and it is never subject to Sentinel per-GB
> analysis charges.

### PRISM vs. MPARR — total monthly cost over time @ 5M records/day

| Horizon | **PRISM** | MPARR plain LA | MPARR + Sentinel |
|---------|----------:|---------------:|-----------------:|
| **Month 1** | **~$390** | ~$658 | ~$1,150 |
| **Year 1 (avg)** | **~$410** | ~$770 | ~$1,260 |
| **Year 3** | **~$525** | ~$1,375 | ~$1,870 |
| **Year 5** | **~$630** | ~$1,870 | ~$2,360 |

> At 5M/day PRISM wins from **month 1** and the gap **widens every year**: MPARR's
> ingestion (and Sentinel analysis) scale **linearly** with the 5× volume, while retention
> (~205 GB/month added) compounds at ~$0.10/GB-month. PRISM's lake grows too, but at
> **~5× lower** per-GB retention (~10× in Cool), so its total stays a fraction of MPARR's.

### The two dimensions where PRISM's flat cost wins decisively

- **Retention horizon.** PRISM's bill barely moves as data ages; MPARR's retention line
  compounds forever. Multi-year compliance archives are exactly where the crossover hits.
- **Data volume.** PRISM is **fixed-infrastructure dominated** — ~$383 at 1M/day is
  ~$390 at 5M/day. MPARR ingestion is **purely linear**: at **5M records/day** MPARR
  pays **~$580/month in Log Analytics ingestion alone** (~$1,070 with Sentinel), plus
  host and retention → **~$658/mo (plain) or ~$1,150/mo (Sentinel)** in month 1 and
  climbing, while PRISM stays ~flat and wins outright.

| Scenario (secure, month 1) | **PRISM** | MPARR plain LA | MPARR + Sentinel |
|----------------------------|----------:|---------------:|-----------------:|
| 100K records/day (~4 GB/mo) | ~$307 | ~$75 | ~$85 |
| **1M records/day (~41 GB/mo)** | **~$383** | **~$178** | **~$267** |
| **5M records/day (~205 GB/mo)** | **~$390** | **~$658** | **~$1,150** |

> The crossover moves with volume: at **100K/day** MPARR is far cheaper, at **1M/day**
> it's still cheaper month 1 (until retention compounds), and by **5M/day PRISM is
> cheaper from day one** — because PRISM's cost barely moves while MPARR's scales with
> every GB. Retention only widens the gap further at every volume.

> **Bottom line on cost:** at low volume and short retention MPARR's secure deployment is
> **cheaper per month**, but its cost **scales with both data volume and retention** and
> comes with a **host to patch and operate**. PRISM trades a higher, **flat** platform
> cost for **volume- and retention-independent** economics — so it wins as data grows and
> ages, which is the defining trait of long-term audit/compliance archives. *(All figures
> are list-price estimates; EA/CSP discounts and Log Analytics commitment tiers apply.)*

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
| Landing cost | ~$0/GB (write to lake) | ~$2.90/GB ingested |
| Long-term retention | ~$0.02/GB-month (~$0.01 Cool) | ~$0.10/GB-month (grows forever) |
| Est. secure cost (month 1) | **~$383 @1M/day · ~$390 @5M/day — flat** | ~$178 @1M/day · ~$658 @5M/day (plain LA; more w/ Sentinel), **grows** |
| Consume from | Power BI, Fabric, Synapse, any SIEM | Log Analytics / Power BI |
| Security | MI + Key Vault + private endpoints + NSP, **no host** | Key Vault + private endpoints + NSP **on a host you patch** |
| Best for | Modern, low-maintenance, cost-efficient, tool-agnostic reporting | Turnkey prebuilt reports on Log Analytics/Sentinel |

> **Bottom line:** PRISM turns Microsoft 365 audit reporting into a **modern,
> serverless, deploy-your-own-instance** solution — cheaper to retain, near-zero to
> maintain, secure by default, and open to any analytics tool.
