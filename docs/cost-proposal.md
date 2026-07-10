# PRISM — Cost Proposal (1,000,000 records / day)

> **Scope:** Estimated monthly Azure cost for the architecture currently defined in `infra/` with **all five audit workloads enabled** (`exchange, sharepoint, dlp, general, azuread`) plus the `entrausers` snapshot, at a sustained volume of **1 million audit records per day** (~30M/month) spread across the streams.
> **Region:** West Europe · **Currency:** USD · **Pricing:** Pay-as-you-go list prices, retrieved live from the Azure Retail Prices API (June 2026). Taxes and any EA/CSP discounts excluded.
> **Record size is measured, not assumed.** Counting **every record in all 198 files** currently in the live data lake (`dlprismc63wet/auditlogs`) gives a weighted-average record size of **~1.48 KB JSON** (see §0) — so **1M records/day ≈ 1.37 GB/day ≈ ~41 GB/month**. This confirms the original ~1.5 KB planning assumption.
> **Which workloads deploy is configurable** via `enabledWorkloads` (`infra/main.parameters.json`). A **single, shared Stream Analytics job** drains all enabled workloads (one input/output per workload), so adding a workload no longer adds a whole streaming job — see §5.

---

## 0. Empirical basis — measured from every file in the live data lake

Record size is not assumed — it is computed by downloading and counting **every record in all 198 blobs** in the deployed data lake account **`dlprismc63wet`**, container **`auditlogs`**, over the window **2026-07-02 → 2026-07-09 (8 days)**. Records land as newline-delimited JSON written by the shared Stream Analytics job, one folder per workload.

| Workload folder | Files | Data | Records | Measured avg record size |
|-----------------|------:|-----:|--------:|-------------------------:|
| `general-json` | 113 | 7.46 MB | 6,231 | **~1,255 B** |
| `sharepoint-json` | 13 | 2.75 MB | 1,268 | **~2,274 B** |
| `exchange-json` | 24 | 0.44 MB | 187 | **~2,477 B** |
| `azuread-json` | 40 | 0.35 MB | 149 | **~2,490 B** |
| `dlp-json` | 8 | 0.09 MB | 46 | **~2,107 B** |
| **Total** | **198** | **11.63 MB** | **7,881** | **~1,476 B (~1.48 KB weighted)** |

- **Measured throughput in the sample window:** 7,881 records over 8 days ≈ **~985 records/day (~1.4 MB/day)** — a light real-world test load.
- **Weighted-average record size: ~1,476 bytes (~1.48 KB)** — driven by the high-volume `general` stream (~1.25 KB), with the other workloads running ~2.1–2.5 KB.

> **Per file vs. per record — why it's ~1.5 KB, not ~57 KB.** A naive `11.63 MB ÷ 198 files ≈ 57 KB` is the average size *per file*, not per record. Each blob is **newline-delimited JSON** and bundles many audit records (one JSON object per line):
>
> - Bytes per **file**: `11,634,450 ÷ 198 ≈ 57 KB`
> - Records per **file**: `7,881 ÷ 198 ≈ 40 records/file`
> - Bytes per **record**: `11,634,450 ÷ 7,881 ≈ 1,476 B ≈ 1.48 KB`  *(equivalently `57 KB/file ÷ 40 records/file ≈ 1.4 KB`)*
>
> Cost at 1M records/**day** scales on the **record** size, because Event Hubs events, Stream Analytics throughput, and data-lake growth all track record count, not file count.

**Extrapolation to the 1,000,000 records/day target** (linear on the measured per-record size, ~1,015× the observed volume):

| Metric | Measured (all 198 files) | Extrapolated @ 1M/day |
|--------|-------------------------:|----------------------:|
| Records/day | ~985 | **1,000,000** |
| Avg record size | ~1.48 KB | ~1.48 KB (unchanged) |
| Data/day | ~1.4 MB | **~1.37 GB** |
| Data/month (30 d) | ~42 MB | **~41 GB** |
| Avg events/sec | ~0.011 | **~11.6** |

> The exact ~1.48 KB record size lands right on the original ~1.5 KB assumption, so the monthly volume (~41 GB) and the cost figures below are confirmed rather than revised. Because the pipeline is **fixed-infrastructure dominated** (§4) and 11.6 events/s is a tiny fraction of one Event Hubs TU / Stream Analytics SU, data volume has almost no effect on the total.

---

## 1. What's deployed (cost-relevant inventory)

Derived from `infra/modules/*.bicep` with all five workloads enabled:

| # | Resource | SKU / config | Count | Billing model |
|---|----------|--------------|-------|---------------|
| 1 | **Stream Analytics job** | Standard, **1 SU**, runs 24/7, **multi-input / multi-output** (1 input + 1 output folder per workload) | **1 (shared)** | Per SU-hour (fixed) |
| 2 | **Private Endpoints** | Standard | **22** | Per hour + per GB processed |
| 3 | **Event Hubs namespace** | Standard, **1 TU**, 5 hubs × 4 partitions, 1-day retention, Capture **off** | 1 ns / 5 hubs | Per TU-hour + per 1M events |
| 4 | **Function Apps** | Flex Consumption (FC1), 2048 MB, Python 3.12 | **6** | Per GB-s + per execution |
| 5 | **Function host storage** | Standard_LRS, StorageV2 | **6** | Storage + transactions |
| 6 | **Data Lake (ADLS Gen2)** | Standard_LRS, HNS on, Hot | 1 | Storage + transactions |
| 7 | **Log Analytics + App Insights** | PerGB2018; 6 App Insights → 1 workspace | 1 + 6 | Per GB ingested |
| 8 | **Key Vault** | Standard | 1 | Per 10k operations |
| 9 | **Private DNS zones** | 6 zones + VNet links | 6 | Per zone/month + queries |
| 10 | VNet + 2 subnets | — | 1 | Free |

**Private endpoint breakdown (22):** 6 Function Apps × 3 (blob + queue + table) = **18**, Data Lake (blob + dfs) = **2**, Event Hubs namespace = **1**, Key Vault = **1**.

---

## 2. Confirmed unit prices (West Europe, live retail API)

| Meter | Price |
|-------|-------|
| Stream Analytics — Standard Streaming Unit | **$0.12 / SU-hour** |
| Event Hubs — Standard Throughput Unit | **$0.03 / TU-hour** |
| Event Hubs — Standard Ingress Events | **$0.028 / 1M events** |
| Private Endpoint | **$0.01 / hour** (+ ~$0.01/GB processed) |
| ADLS Gen2 — Standard LRS, Hot | ~$0.0196 / GB-month |
| Log Analytics — Analytics ingestion | ~$2.90 / GB (first 5 GB/mo free) |
| Private DNS zone | $0.50 / zone-month (+ query charges) |
| Flex Consumption — execution | $0.000016 / GB-s + $0.20 / 1M executions |

> 730 hours/month used for all hourly → monthly conversions.

---

## 3. Monthly cost estimate

| Component | Calculation | Expected / month |
|-----------|-------------|------------------:|
| **Stream Analytics (1 shared job)** | 1 × 1 SU × $0.12 × 730 | **$87.60** |
| **Private Endpoints (22)** | 22 × $0.01 × 730 + ~$1.40 data | **$162.00** |
| **Log Analytics + App Insights** | ~18–22 GB ingested net of free tier (6 App Insights) | **$52.00** |
| **Function Apps (6, Flex)** | ~execution GB-s + invocations | **$28.00** |
| **Event Hubs (1 TU)** | $0.03 × 730 + 30M × $0.028/1M | **$22.70** |
| **Data Lake (ADLS Gen2)** | **~41 GB/mo growth** (measured 1.48 KB/rec) + ASA write transactions | **$13.00** |
| **Function host storage (6)** | small footprint + transactions | **$12.00** |
| **Private DNS zones (6)** | 6 × $0.50 + queries | **$4.00** |
| **Key Vault** | reference resolution operations | **$1.00** |
| **VNet / subnets** | — | $0.00 |
| **Total (expected)** | | **≈ $383 / month** |

### Range

| Scenario | Monthly | Notes |
|----------|--------:|-------|
| **Low** | **~$330** | Lean logging (sampling on), data lake new/small |
| **Expected** | **~$383** | All 5 workloads, single shared ASA job |
| **High** | **~$445** | Verbose telemetry (30+ GB logs) and Event Hubs auto-inflate to 2 TU under bursty delivery. The shared Stream Analytics job stays at **1 SU** — 1M/day (~11.6 events/s) is a tiny fraction of one SU, so it never needs scaling up. |

> **~$0.013 per 1,000 records** (≈ $13 per million) at this volume with all five workloads on. See §5 to scale cost down by disabling workloads.

### 3.1 Lower volume — 10,000 records/day (~300K/month)

Dropping ingestion by **100×** barely moves the bill, because the cost is fixed-infrastructure dominated (§4). Only the tiny volume-sensitive meters shrink:

| Component | 1M/day | 10K/day | Change |
|-----------|-------:|--------:|--------|
| Stream Analytics (1 shared job) | $88 | $88 | — (fixed SU) |
| Private Endpoints (22) | $162 | $161 | ~$0 (data charge gone) |
| Log Analytics + App Insights | $52 | ~$12 | lower trace volume |
| Function Apps (6) | $28 | ~$5 | fewer executions |
| Event Hubs (1 TU) | $23 | $22 | ingress ≈ $0 |
| Data Lake | $13 | ~$2 | ~0.5 GB/mo growth |
| Everything else | $17 | $17 | — |
| **Total (expected)** | **~$383** | **≈ $307 / month** | **only ~$75 less** |

> At 10K/day the effective unit cost is **~$1.02 per 1,000 records** — ~80× higher per record than at 1M/day, purely because the same fixed platform is spread over far fewer records. **To cut cost at low volume, disable unneeded workloads (§5) — reducing ingestion volume does almost nothing.**

---

## 4. Key insight: cost is dominated by *fixed* infrastructure, not volume

At 1M records/day the actual data path is tiny — **~11.6 events/second average** (measured record size ~1.48 KB → ~17 KB/s), a small fraction of one Event Hubs throughput unit and well under one Stream Analytics streaming unit. The bill is driven almost entirely by **always-on, fixed-price resources**:

```
Private Endpoints $162  ┃██████████████████████████████  42%
Stream Analytics  $88   ┃████████████████                23%
Logging           $52   ┃██████████                      14%
Functions         $28   ┃█████                            7%
Event Hubs        $23   ┃████                             6%
Everything else   $30   ┃█████                            8%
```

**~80% of the bill (~$300) is fixed** and would be nearly identical at 100K/day or 5M/day. With the consolidated Stream Analytics job, **private endpoints are now the single largest line** and the fixed platform no longer grows much as workloads are added.

---

## 5. Turning workloads on/off (`enabledWorkloads`) and cost impact

The `enabledWorkloads` parameter (`infra/main.parameters.json`) controls which
audit APIs deploy. Each entry provisions a **complete, isolated pipeline** —
Function App, Event Hub, runtime storage, 3 private endpoints, App Insights, and
role assignments — **plus one input/output on the shared Stream Analytics job**.
Adding an entry and re-running `azd provision` **creates that pipeline and starts
its charges**.

> **Note — removing a workload does not auto-delete it.** `azd provision` runs an
> **incremental** ARM/Bicep deployment, so simply dropping an entry from
> `enabledWorkloads` leaves the previously-created resources in place and they
> **keep accruing cost**. To actually stop the charges you must remove those
> resources explicitly — e.g. delete the workload's resources in the portal/CLI,
> or tear down the whole environment with `azd down`.

The `entrausers` snapshot function is **always deployed** and is not part of this
toggle.

### Cost model

> **Total ≈ fixed baseline + one shared ASA job + (per-workload cost × number of enabled workloads)**

- **Fixed platform baseline ≈ $130/month** — shared regardless of workload count:
  Event Hubs namespace (1 TU), Data Lake, Key Vault, the 6 private DNS zones, the
  shared private endpoints (Data Lake ×2, Event Hubs, Key Vault), base logging,
  and the always-on `entrausers` function stack.
- **Shared Stream Analytics job ≈ $88/month** — a **flat** 1-SU cost added once
  any workload is enabled; it does **not** grow as you add more workloads.
- **Per enabled workload ≈ $32/month** — its Function App, host storage, its **3
  runtime-storage private endpoints (~$22)**, and App Insights. Event Hub
  throughput and the ASA job are shared, so extra workloads add little.

| Enabled workloads | Example | Est. monthly |
|-------------------|---------|-------------:|
| **5 (all)** | exchange, sharepoint, dlp, general, azuread | **~$383** |
| 4 | drop one workload | ~$350 |
| 3 | exchange, sharepoint, dlp | ~$320 |
| 2 | e.g. exchange, dlp | ~$285 |
| 1 | single workload | ~$250 |
| 0 | `entrausers` only (no ASA job) | ~$130 |

> Consolidating to one Stream Analytics job already removed the biggest cost
> driver (5 × $88 → 1 × $88). **Adding or removing a workload now costs only
> ~$32/month** instead of ~$120, because workloads share the single job.

---

## 6. Optimization options

Ranked by savings. Each is optional and trades cost against isolation/architecture.

| # | Change | Est. saving/mo | Trade-off |
|---|--------|---------------:|-----------|
| 1 | **Disable workloads you don't need** via `enabledWorkloads` (see §5). | **~$32 per workload** | You lose that audit stream entirely. |
| 2 | **Reduce private endpoints** — share one runtime storage account across the Function Apps and/or use service endpoints for low-sensitivity storage. 18 of 22 PEs are function-storage. | **~$80–130** | Less per-app isolation; service endpoints are subnet- not resource-scoped. |
| 3 | **Drop Stream Analytics + Event Hubs entirely** — have each Function write JSON straight to the data lake. Trivial load at 1M/day. | **~$110** (ASA + EH) | Lose buffering/replay and the EH decoupling layer; Functions own delivery + batching. |
| 4 | **Tighten telemetry** — enable App Insights sampling, cap log ingestion, set a daily quota. | **~$25–45** | Lower trace fidelity for debugging. |
| 5 | **Lifecycle management on the lake** — auto-tier to Cool after 90 days / delete after retention. | grows over time | Older data slower/cheaper to read. |

> **Already applied:** the 5 per-workload Stream Analytics jobs were consolidated into **one shared multi-input/output job** (~$350/mo saved vs. a job per workload) while keeping each workload's Event Hub, Function App, and data-lake folder separate.

**If you apply #2 + #4** (keeping all 5 workloads), expected cost drops to roughly **$230–280/month**. Disabling workloads (#1) reduces it further at ~$32 each — the remaining price reflects the *secure, fully-isolated, decoupled* design, not the data volume.

---

## 7. Assumptions & caveats

- Average record **~1.48 KB (measured across all 198 files)** in the live lake (§0); per-workload it ranges from ~1.25 KB (`general`, the high-volume stream) to ~2.5 KB (Entra ID / Exchange). 1M records/day ≈ **~41 GB/month** — scale storage/logging linearly if the workload mix shifts toward the larger record types.
- Bursty M365 delivery is within **1 TU**; if peaks exceed ~1000 events/s, enable **auto-inflate** (small added TU-hours).
- `entrausers` timer runs **daily at 02:00 UTC** (`0 0 2 * * *`) — modest Graph calls, function executions, and one lake write per day.
- The single Stream Analytics job is **created stopped**; charges begin only once you **start** it (see the README). A stopped job costs nothing.
- Flex Consumption has no always-ready instances configured (scales to zero), so function cost is execution-driven and modest.
- Prices are **list / PAYG**; EA, CSP, or savings commitments reduce them. Reservations don't apply to most of these meters.
- The Data Lake's public access is governed by a **Network Security Perimeter**; the perimeter, its profile, and access rules incur **no Azure charge**.
- Excludes egress/bandwidth, Microsoft 365 / Graph licensing, and the Entra app registration (no Azure cost).
