# Final demonstration guide (~30 minutes, 4 presenters)

Each member demonstrates **2 requirements + 2 services** (as in `task_divison.txt`). Every step names the requirement it proves, what to open, what to run, what the panel should see, and the screenshot to keep. All commands are PowerShell 7 in `C:\dev\s19-disaster-management`. Copy commands from the **rendered** page on GitHub (inside tables the raw Markdown shows `\|` where the command has `|`). `s19` is the helper from `scripts/env.ps1` (README 5.3).

---

## Preparation (T-90 to T-15 minutes)

| When | Do | Expected |
|---|---|---|
| T-90 | 💲 Resume the platform (README 17.2) with `use_spot_nodes = false` in `01-foundation/terraform.tfvars` (no preemption during the demo) | `Apply complete!` twice |
| T-80 | 💲 Set `dataproc_enabled = true`, `terraform -chdir=infra/terraform/01-foundation apply`, then `terraform -chdir=infra/terraform/02-platform apply` (README 13.3) | Dataproc cluster `s19-flink` RUNNING |
| T-70 | `kubectl -n argocd get applications` | all 5 `Synced Healthy` |
| T-65 | `.\scripts\submit_flink_job.ps1 -ProjectId $env:PROJECT_ID` | job `RUNNING` |
| T-60 | `. .\scripts\env.ps1` ; `.\.venv\Scripts\Activate.ps1` ; `s19 POST "/api/volunteers/_seed?perRegion=8"` | `HTTP 201 {"seeded": 40}` |
| T-55 | `python scripts/e2e_check.py --flink` | `30/30 checks passed` (29 + Flink) |
| T-45 | warm-up traffic so graphs and Flink windows have data: `k6 run -e BASE_URL=$env:BASE_URL -e PEAK_VUS=10 -e HOLD=3m loadtest/k6/hpa-load.js` | k6 thresholds ✓ |
| T-20 | Open the tabs below and log in | — |
| T-15 | Let replicas scale back to 1: `kubectl -n s19 get hpa` shows REPLICAS 1 | — |

**Browser tabs to open (in this order):**
1. GitHub repo (code, `deploy/`, Actions tab)
2. Argo CD — `kubectl -n argocd port-forward svc/argocd-server 9080:80` → <http://localhost:9080>
3. Grafana — `kubectl -n monitoring port-forward svc/kps-grafana 3000:80` → <http://localhost:3000> → dashboard **S19 Disaster Management - Overview**, time range *Last 30 minutes*, refresh *10s*
4. GCP Console → **Kubernetes Engine → Workloads** (namespace `s19`)
5. GCP Console → **Cloud Run → alert-service → Logs**
6. GCP Console → **Dataproc → Clusters → s19-flink → Web Interfaces → YARN ResourceManager → ApplicationMaster** (Flink UI)
7. GCP Console → **Firestore → (default) → Data**
8. GCP Console → **Cloud Storage → `<id>-s19-data`**, **SQL → s19-pg**
9. GCP Console → **Logging → Logs Explorer**
10. Optional: your ntfy/Slack/Discord webhook page (if `alert_webhook_url` is set)

**Terminals:** T1 commands (env loaded), T2 `kubectl -n s19 get hpa -w`, T3 for k6, T4 for port-forwards.

**Test records used in the demo** (create them live; the ids printed are used later):

| Variable | Record | Created in |
|---|---|---|
| `$inc` | HIGH FLOOD, region `north`, reporter `demo-officer-1`, 40 people | A2 |
| `$crit` | CRITICAL CYCLONE, region `east`, reporter `demo-citizen-7`, 1200 people | B1 |
| `$fire` | HIGH FIRE, region `west`, reporter `demo-officer-2` | D1 |

---

## 0. Overview — any member (2 min)

| Step | Requirement | Show | Say |
|---|---|---|---|
| O1 | Deliverables | `docs/DESIGN.md` §2 diagram on GitHub | 8 services, GCP, which runs where |
| O2 | Public URL | browser: `http://<INGRESS_IP>/api/quorum/config` | GKE Ingress = global external ALB on a Terraform-reserved static IP |
| O3 | G1 | Console **Kubernetes Engine → Workloads** (namespace `s19`) + Cloud Run `alert-service` + Dataproc job | 7 containerised services + 1 function + Flink job |

📸 Screenshot: Workloads page; browser with the JSON from O2.

---

## A. Member 1 — Replicated Incident Store + Quorum Coordinator · requirements (f) and (c)

| Step | Req | Run (T1) | Expected / point at |
|---|---|---|---|
| A1 | f | `s19 GET /api/quorum/config` | `n=3, w=2, r=2, rPlusWGreaterThanN=true`: every read quorum overlaps every write quorum |
| A2 | f | `$r = s19 POST /api/incidents @{reporterId='demo-officer-1'; type='FLOOD'; severity='HIGH'; region='north'; description='river overflow at the old bridge'; latitude=28.61; longitude=77.21; peopleAffected=40} -Raw; $inc = $r.incidentId; $r.quorum \| ConvertTo-Json` | `acks` 2 or 3 of `n` 3: the write returned as soon as W=2 replicas acknowledged |
| A3 | f (failure) | `s19 POST /api/quorum/replicas/incident-store-2/fault @{mode='down'} -Admin` then the A2 command again with `description='written while replica 2 is down'`, then `s19 GET /api/quorum/debug/$inc` | write still `HTTP 201` with `acks: 2`; replica 2 entry `error: UNAVAILABLE ...` |
| A4 | f (recovery) | `s19 POST /api/quorum/replicas/incident-store-2/fault @{mode='none'} -Admin` ; `s19 POST /api/quorum/anti-entropy -Admin` ; `s19 GET /api/quorum/debug/$inc` | `differingBuckets ≥ 1`, `repaired: {incident-store-2: n}`; all three replicas identical (Merkle-lite anti-entropy) |
| A5 | f (read repair) | README 12.3 commands with `$id = $inc` | `staleReplicasInQuorum: ["incident-store-0"]`, then replica 0 repaired |
| A6 | f (conflict) | README 12.4 commands with `$id = $inc` | `conflict: true`, two sibling clocks that are concurrent, merged value keeps `DISPATCHED` **and** `CRITICAL`; next read `conflict: false` |
| A7 | f (quorum loss) | `python scripts/consistency_test.py` (≈15 s, all scenarios incl. W=2 rejected / W=1 accepted / R=2 failing) | `14/14 checks passed` |
| A8 | f (real crash) | T3: `k6 run -e BASE_URL=$env:BASE_URL loadtest/k6/smoke.js`; T1 during it: `kubectl -n s19 delete pod incident-store-1` ; `kubectl -n s19 get pods -l app=incident-store` | smoke `checks 100%`; pod recreated with the same name/volume; Grafana **Replicas up (of 3)** dips to 2 and returns to 3; `kubectl -n s19 get pdb` → min available 2 |
| A9 | c (HPA + load) | T2 already shows `kubectl -n s19 get hpa -w`; T3: `k6 run -e BASE_URL=$env:BASE_URL -e HOLD=4m loadtest/k6/hpa-load.js` | within 1–3 min `incident-intake` and `quorum-coordinator` go 1 → 3 → 5; Grafana **HPA current vs desired replicas** and **RPS by service** rise; k6 ends with thresholds ✓ |
| A10 | c | `Get-Content docs/evidence/hpa-scaling.log -Tail 30` (recorded earlier, README 15.2) | logged scale-out with timestamps |

📸 Screenshots: A3 debug output, A4 anti-entropy result, A6 merged value, A7 summary, A8 Grafana replicas panel, A9 HPA watch + Grafana HPA panel + k6 summary.

**Likely questions:** *Why W=2,R=2?* R+W>N gives read-your-latest-write with one failure tolerated for both reads and writes. *Why no hinted handoff?* With exactly 3 nodes there is no spare node to hold hints; anti-entropy gives the same eventual repair and keeps the coordinator stateless. *How are conflicts detected?* Vector clocks: neither clock descends the other → siblings. *What if the coordinator dies?* It is stateless and HPA-scaled; any pod serves any request.

---

## B. Member 2 — Incident Intake + Alert Service (serverless) · requirements (b) and (g)

| Step | Req | Run / open | Expected / point at |
|---|---|---|---|
| B1 | b (REST → Pub/Sub → function) | `$c = s19 POST /api/incidents @{reporterId='demo-citizen-7'; type='CYCLONE'; severity='CRITICAL'; region='east'; description='cyclone landfall, coastal villages flooding'; latitude=22.57; longitude=88.36; peopleAffected=1200} -Raw; $crit = $c.incidentId; $c \| ConvertTo-Json -Depth 5` | `alertPublished: true`, `kafkaEventQueued: true` |
| B2 | b (serverless, async, event-driven) | wait ~15 s; tab **Cloud Run → alert-service → Logs**; `s19 GET "/api/analytics/alerts?limit=2"`; `s19 GET /api/volunteers/broadcasts/east` | log lines `notification delivered` / `alert processed`; alert record with `channels`, `delivered`, `failed: 0`; the broadcast; (webhook page shows the alert if configured) |
| B3 | b (each mechanism) | REST: B1. gRPC: `s19 GET /api/quorum/debug/$crit` and show `proto/incident_store.proto`. Kafka: `kubectl -n kafka exec kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic incident-events --from-beginning --max-messages 3`. Pub/Sub: Console **Pub/Sub → alert-requests → Metrics** | all four mechanisms visible |
| B4 | g (object store) | `"flood photo" \| Set-Content $env:TEMP\flood.jpg; Invoke-RestMethod -Method Post -Uri "$env:BASE_URL/api/incidents/$crit/attachments" -Form @{file=Get-Item $env:TEMP\flood.jpg}` ; Console **Cloud Storage → bucket → attachments/** and **raw/incidents/** | `gs://…/attachments/<id>/…` object; NDJSON raw batches (flushed every 30 s) |
| B5 | g (SQL + NoSQL) | Console **SQL → s19-pg** (overview); `s19 GET "/api/resources?region=east&status=RESERVED"`; Console **Firestore → Data** → `volunteers`, `alerts`, `notifications`, `broadcasts`, `analytics_windows` | relational rows (reserved by the auto-dispatch of `$crit`) and documents |

📸 Screenshots: B1 response, B2 function logs + alert record, B3 Kafka consumer, B4 GCS object, B5 Firestore collections, Cloud SQL overview.

**Likely questions:** *Why a function for alerts?* Bursty, asynchronous, no state between calls, scales to zero. *What if delivery fails?* Firestore errors raise → Pub/Sub redelivers; duplicates are ignored by message id; per-delivery `FAILED` is recorded for the webhook. *Why three stores?* GCS = cheap immutable raw archive; Cloud SQL = transactions + row locks for reservations; Firestore = high-churn semi-structured docs.

---

## D. Member 3 — Resource Registry + Dispatch · requirements (a) and (d)

| Step | Req | Run / open | Expected / point at |
|---|---|---|---|
| D1 | services | `$f = s19 POST /api/incidents @{reporterId='demo-officer-2'; type='FIRE'; severity='HIGH'; region='west'; description='warehouse fire near the port'; latitude=19.07; longitude=72.88; peopleAffected=15} -Raw; $fire = $f.incidentId` ; `$d = s19 POST /api/dispatch @{incidentId=$fire} -Raw; $d \| ConvertTo-Json -Depth 5` ; `s19 GET /api/incidents/$fire` | dispatch with 2 `resource_ids` (Cloud SQL `FOR UPDATE SKIP LOCKED`) and 3 `volunteer_ids` (Firestore transaction); incident now `DISPATCHED` via a quorum write |
| D2 | services | `s19 GET "/api/dispatch?status=ACTIVE&limit=5"` | the AUTO dispatch of `$crit` (created from Kafka in B1) next to the MANUAL one |
| D3 | a (IaC) | `terraform -chdir=infra/terraform/01-foundation state list \| Measure-Object` ; `terraform -chdir=infra/terraform/01-foundation plan` ; open `infra/terraform/01-foundation/gke.tf` on GitHub | about 80 entries (resources + data sources); plan says **No changes. Your infrastructure matches the configuration.** |
| D4 | d (GitOps) | Edit `deploy/k8s/base/hpa.yaml`: `maxReplicas: 5` → `6` for `incident-intake`; `git commit -am "demo: allow 6 intake replicas"; git push` ; Argo CD tab → `s19-services` → **REFRESH** | app goes **OutOfSync → Syncing → Synced**; `kubectl -n s19 get hpa incident-intake` shows `MAXPODS 6`. Explain: no `kubectl apply`; CI only commits image tags (show **Actions** run + the `deploy: images … [skip ci]` commit) |
| D5 | services | `s19 POST "/api/dispatch/$($d.dispatch.id)/complete"` ; `s19 GET /api/incidents/$fire` | `COMPLETED`, `resourcesReleased: 2`, incident `RESOLVED` |

📸 Screenshots: D1 response, D3 plan "No changes", D4 Argo CD before/after sync + GitHub commit.
After the demo revert D4 (`git revert HEAD; git push`).

**Likely questions:** *How do you avoid double-booking a vehicle?* `SELECT … FOR UPDATE SKIP LOCKED` inside a transaction plus a unique partial index on active reservations. *What if the incident write fails after reserving?* Dispatch rolls back the reservations, marks the dispatch FAILED and writes a compensating incident version (DESIGN §4.3). *Who creates the Kubernetes Secrets?* Terraform `02-platform`, so no secret is in Git.

---

## C. Member 4 — Volunteer Coordination + Situation Analytics (Flink) · requirements (e) and (h)

| Step | Req | Run / open | Expected / point at |
|---|---|---|---|
| C1 | services | `s19 GET /api/volunteers/stats` (before/after D1) ; `s19 GET "/api/volunteers/$($d.dispatch.volunteer_ids[0])/notifications"` | assigned counts change; the volunteer's inbox holds the DISPATCH_ASSIGNED alert |
| C2 | e (Flink on Dataproc) | Flink UI tab: job graph, **Checkpoints**; `gcloud dataproc jobs list --region us-central1 --cluster s19-flink` | operators *kafka source → parse → watermarks → tumbling-window-per-region → surge-detector-keyed-state → kafka sink*; completed checkpoints; job RUNNING |
| C3 | e (Kafka in/out, stateful window) | `kubectl -n kafka exec kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic incident-aggregates --max-messages 2` (wait ≤ 60 s) ; `s19 GET "/api/analytics/windows?region=north&limit=3"` ; `s19 GET /api/analytics/summary` | per-region 1-minute results with `uniqueReporters`, `incidents`, `critical`, `dispatches`, `conflicts`, `readRepairs`, `baseline`, `surge`; summary combines Flink windows + Registry + Volunteers + Coordinator |
| C4 | h (metrics) | Grafana dashboard | RPS, 5xx error rate, p50/p95/p99 latency per service; nodes ready, pod restarts, HPA; Dynamo panels; Flink uptime/checkpoints/records |
| C5 | h (logging) | Logs Explorer: `resource.type="k8s_container" AND resource.labels.namespace_name="s19"`, then `jsonPayload.service="quorum-coordinator"`, then `resource.type="cloud_run_revision" AND resource.labels.service_name="alert-service"`, then `resource.type="cloud_dataproc_cluster" AND resource.labels.cluster_name="s19-flink"` | one place for logs of all services, the function **and the Flink job** |

📸 Screenshots: C2 Flink graph + checkpoints, C3 window JSON, C4 dashboard (full page), C5 each Logs Explorer query.

**Likely questions:** *Why event time?* Late or reordered Kafka events still land in the right minute (10 s bounded out-of-orderness). *Where is state?* Window accumulators (counts + reporter set) and the per-region EWMA `ValueState`, checkpointed to HDFS every 30 s. *How are unique reporters counted?* A `HashSet` per region-window inside the accumulator.

---

## Closing (1 min) and after the demo

1. Console → **Billing → Reports**: credit used so far.
2. Revert the GitOps demo change: `git revert HEAD; git push`.
3. 💲 Stop paying: set `dataproc_enabled = false`, then README **17.1** (pause) — or **17.3** after grading.

## Requirement → demo step map

| Req | Steps |
|---|---|
| a | D3 |
| b | B1, B2, B3 (+ A2 REST, A-series gRPC) |
| c | A9, A10, O3 |
| d | D4 |
| e | C2, C3 |
| f | A1–A8 |
| g | B4, B5 |
| h | C4, C5 |
| public URL / 8 services | O2, O3 |
