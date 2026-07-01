# PRISM — Cost Proposal (1,000,000 records / day)

> **Scope:** Estimated monthly Azure cost for the architecture currently defined in `infra/` at a sustained volume of **1 million audit records per day** (~30M/month).
> **Region:** West Europe · **Currency:** USD · **Pricing:** Pay-as-you-go list prices, retrieved live from the Azure Retail Prices API (June 2026). Taxes and any EA/CSP discounts excluded.
> Estimates assume average record size **~1.5 KB JSON** → **~1.5 GB/day ingress (~45–50 GB/month)**.

---

## 1. What's deployed (cost-relevant inventory)

Derived from `infra/modules/*.bicep`:

| # | Resource | SKU / config | Count | Billing model |
|---|----------|--------------|-------|---------------|
| 1 | **Stream Analytics jobs** | Standard, **1 SU each**, runs 24/7 | **3** | Per SU-hour (fixed) |
| 2 | **Private Endpoints** | Standard | **16** | Per hour + per GB processed |
| 3 | **Event Hubs namespace** | Standard, **1 TU**, 3 hubs × 4 partitions, 1-day retention, Capture **off** | 1 ns / 3 hubs | Per TU-hour + per 1M events |
| 4 | **Function Apps** | Flex Consumption (FC1), 2048 MB, Python 3.12 | **4** | Per GB-s + per execution |
| 5 | **Function host storage** | Standard_LRS, StorageV2 | **4** | Storage + transactions |
| 6 | **Data Lake (ADLS Gen2)** | Standard_LRS, HNS on, Hot | 1 | Storage + transactions |
| 7 | **Log Analytics + App Insights** | PerGB2018; 4 App Insights → 1 workspace | 1 + 4 | Per GB ingested |
| 8 | **Key Vault** | Standard | 1 | Per 10k operations |
| 9 | **Private DNS zones** | 6 zones + VNet links | 6 | Per zone/month + queries |
| 10 | VNet + 2 subnets | — | 1 | Free |

**Private endpoint breakdown (16):** 4 Function Apps × 3 (blob + queue + table) = **12**, Data Lake (blob + dfs) = **2**, Event Hubs namespace = **1**, Key Vault = **1**.

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
| **Stream Analytics (3 jobs)** | 3 × 1 SU × $0.12 × 730 | **$262.80** |
| **Private Endpoints (16)** | 16 × $0.01 × 730 + ~$1 data | **$117.80** |
| **Log Analytics + App Insights** | ~15–20 GB ingested net of free tier | **$45.00** |
| **Event Hubs (1 TU)** | $0.03 × 730 + 30M × $0.028/1M | **$22.70** |
| **Function Apps (4, Flex)** | ~execution GB-s + invocations | **$20.00** |
| **Data Lake (ADLS Gen2)** | ~50 GB growth + ASA write transactions | **$12.00** |
| **Function host storage (4)** | small footprint + transactions | **$8.00** |
| **Private DNS zones (6)** | 6 × $0.50 + queries | **$4.00** |
| **Key Vault** | reference resolution operations | **$1.00** |
| **VNet / subnets** | — | $0.00 |
| **Total (expected)** | | **≈ $493 / month** |

### Range

| Scenario | Monthly | Notes |
|----------|--------:|-------|
| **Low** | **~$450** | Lean logging (sampling on), data lake new/small |
| **Expected** | **~$493** | Assumptions above |
| **High** | **~$580** | Verbose telemetry (30+ GB logs), Event Hubs auto-inflate to 2 TU, larger records |

> **~$0.49 per 1,000 records** at this volume.

---

## 4. Key insight: cost is dominated by *fixed* infrastructure, not volume

At 1M records/day the actual data path is tiny — **~11.6 events/second average**, a small fraction of one Event Hubs throughput unit and well under one Stream Analytics streaming unit. The bill is driven almost entirely by **always-on, fixed-price resources**:

```
Stream Analytics  $263  ┃████████████████████████████  53%
Private Endpoints $118  ┃████████████                  24%
Logging           $45   ┃████                           9%
Event Hubs        $23   ┃██                             5%
Functions         $20   ┃██                             4%
Everything else   $24   ┃██                             5%
```

**~77% of the bill ($381) is fixed** and would be nearly identical at 100K/day or 5M/day. The volume-sensitive portion (Event Hubs ingress, lake storage, function executions, logs) is small at this scale.

---

## 5. Optimization options

Ranked by savings. Each is optional and trades cost against isolation/architecture.

| # | Change | Est. saving/mo | Trade-off |
|---|--------|---------------:|-----------|
| 1 | **Consolidate 3 Stream Analytics jobs → 1 job** (3 inputs → 3 outputs, 1 SU). 1 SU easily handles all three streams at 1M/day. | **~$175** | One job = shared scaling/monitoring; lose per-pipeline job isolation. |
| 2 | **Drop Stream Analytics + Event Hubs entirely** — have each Function write JSON straight to the data lake. Trivial load at 1M/day. | **~$285** (ASA + EH) | Lose buffering/replay and the EH decoupling layer; Functions own delivery + batching. |
| 3 | **Reduce private endpoints** — share one runtime storage account across the 4 Function Apps and/or use service endpoints for low-sensitivity storage. 12 of 16 PEs are function-storage. | **~$50–90** | Less per-app isolation; service endpoints are subnet- not resource-scoped. |
| 4 | **Tighten telemetry** — enable App Insights sampling, cap log ingestion, set a daily quota. | **~$20–40** | Lower trace fidelity for debugging. |
| 5 | **Lifecycle management on the lake** — auto-tier to Cool after 90 days / delete after retention. | grows over time | Older data slower/cheaper to read. |

**If you apply #2 + #3 + #4**, expected cost drops to roughly **$130–170/month** while still serving 1M records/day — because the workload itself is light; the current price reflects the *secure, fully-isolated, decoupled* design, not the data volume.

---

## 6. Assumptions & caveats

- Average record **1.5 KB**; DLP/Exchange records can run larger — scale storage/logging linearly if so.
- Bursty M365 delivery is within **1 TU**; if peaks exceed ~1000 events/s, enable **auto-inflate** (small added TU-hours).
- `entrausers` timer is set to **every 10 minutes** (`0 */10 * * * *`) in `resources.bicep`, not weekly as the proposal describes — at scale this drives extra Graph calls, function executions, and lake writes. Switching to weekly (`0 0 2 * * 1`) removes ~143 runs/day. Confirm intent.
- Flex Consumption has no always-ready instances configured (scales to zero), so function cost is execution-driven and modest.
- Prices are **list / PAYG**; EA, CSP, or savings commitments reduce them. Reservations don't apply to most of these meters.
- Excludes egress/bandwidth, Microsoft 365 / Graph licensing, and the Entra app registration (no Azure cost).
