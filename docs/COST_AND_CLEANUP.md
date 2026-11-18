# GCP cost management and cleanup guide

**Bottom line:** this assignment cannot run for literally $0 of usage: GKE nodes, Cloud SQL, Dataproc and the load balancers have no always-free tier. On a new-customer **Free Trial** ($300 credit, 90 days, at most **8 vCPUs of Compute Engine running at the same time**, no charge until you upgrade to a paid account) the expected spend is roughly **$10–25 of credit** if you pause between sessions. Without a trial, that range is real money.

Verified in November 2026: the GKE free tier gives **$74.40 per month per billing account**, which covers the management fee of one zonal (or Autopilot) cluster; the trial terms above. All other prices below are **approximate list prices for us-central1** — re-check them in the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) before you start.

## 1. What costs money, and when

| Step in README | Creates | Billable? |
|---|---|---|
| Parts 1–5 (local) | nothing in GCP | **free** |
| 8.1 `00-bootstrap` | state bucket | cents/month (inside the 5 GB free storage) |
| 8.6 `01-foundation` | GKE nodes, Cloud SQL, static IPs, disks; plus free-tier services (Firestore, Pub/Sub, function, Artifact Registry) | **💲 yes — ~$0.15–0.22/hour while running** |
| 9.2 image push | Artifact Registry storage | ≈ free (0.5 GB free) |
| 10.4 `02-platform` | Argo CD (on existing nodes); Argo CD then creates the Ingress load balancer, Kafka internal LB, persistent disks | **💲 yes — load balancers ≈ $0.05/hour** |
| 13.3 Dataproc | single-node Flink cluster | **💲 ≈ $0.09/hour** |
| 15.2 load test | the autoscaler may add a 3rd node | **💲 ≈ $0.07/hour while scaled out** |

## 2. Per-resource table

| Resource (Terraform file) | Purpose | Price basis (approx.) | Free tier? | Cost-saving approach |
|---|---|---|---|---|
| GKE management fee (`gke.tf`) | Control plane of `s19-gke` | $0.10/h per cluster | **Yes, via the $74.40/month credit** (one zonal cluster) | Exactly one **zonal** cluster, never regional |
| GKE nodes, 2–3 × e2-standard-2 | Runs the 7 containerised services, Kafka, Prometheus, Grafana and Argo CD | $0.067/h each on-demand; Spot lists around $0.03/h (varies) | No (trial credit) | `use_spot_nodes=true` while developing, `false` on demo day; pause between sessions (§4); autoscaler max 3 |
| Node boot disks, 30 GB pd-standard each | Node OS | about $0.04/GB-month | No | Small pd-standard disks |
| PersistentVolumes: 3 × 1 Gi (replicas) + 2 Gi (Kafka), pd-balanced | Replica and Kafka data | about $0.10/GB-month (≈ $0.50/month total) | No | Tiny volumes; Prometheus and Grafana use emptyDir |
| Node external IPv4 | Image pulls from Docker Hub | in-use IPv4 charge, about $0.005/h per VM | No | Only 2–3 nodes |
| GKE Ingress, global external ALB (`ingress.yaml`) | Public URL | $0.025/h for up to 5 forwarding rules + $0.008/GB processed | No | One Ingress for all paths; static IP reserved only while GKE is enabled |
| Kafka internal LB (`kafka.yaml`) | Dataproc → Kafka | Regional forwarding rule, $0.025/h (regional and global rules are billed separately) | No | Only one regional rule |
| Cloud SQL PostgreSQL db-f1-micro, 10 GB HDD (`cloudsql.tf`) | Resources, reservations, dispatches | about $0.015/h (≈ $8–11/month if 24×7) + HDD storage | **No free tier** | Cheapest shared-core tier, no HA, no backups, private IP; `cloudsql_running=false` stops it (storage is still billed) |
| Dataproc single node e2-standard-2 + Flink (`dataproc.tf`) | Managed Flink cluster | VM $0.067/h + Dataproc fee $0.01 per vCPU-hour (2 vCPU → $0.02/h) + disk ≈ **$0.09/h** | No | `dataproc_enabled=true` only for Flink work and the demo; `idle_delete_ttl` auto-deletes after 2 h idle |
| Kafka broker (self-managed on GKE) | Message queue | $0 extra (uses node capacity) | n/a | Managed Service for Apache Kafka is billed per DCU-hour ($0.09; 1 vCPU = 0.6 DCU, 1 GiB = 0.1 DCU) plus storage (100 GiB billed per vCPU). Example: a 3 vCPU/12 GiB cluster is about $0.27/h compute alone. Not needed, because the assignment says the Kafka cluster *may* be managed |
| Cloud Storage bucket `*-s19-data` (`data_stores.tf`) | Raw reports, attachments, function source, Flink jar | Standard storage + operations | **Yes**: 5 GB-month Standard in us-central1/us-east1/us-west1, 5,000 Class A and 50,000 Class B operations per month | Regional us-central1; raw reports written in NDJSON **batches**; 30-day lifecycle delete |
| Firestore `(default)` (`data_stores.tf`) | Volunteers, alerts, analytics windows | per document read/write | **Yes**: 1 GiB + 50k reads, 20k writes, 20k deletes per day (default database) | Only CRITICAL incidents (2% in k6) trigger alert writes; window results are 1 doc per region per minute |
| Pub/Sub topic `alert-requests` | Alert queue | per GiB | **Yes**: 10 GiB/month | Small JSON messages |
| Cloud Run function `alert-service` (`function.tf`) | Serverless Alert Service | invocations + compute | **Yes**: 2M invocations/month | `min_instance_count=0` |
| Cloud Build (function build) | Builds the function | build-minutes | Free monthly build-minute allotment covers a few builds | Rebuilds only when the source zip hash changes |
| Artifact Registry `s19` | Container images | storage | **Yes**: 0.5 GB | One shared dependency layer for all 7 images; cleanup policy keeps 3 versions |
| Cloud Logging | Centralised logs | ingestion | **Yes**: 50 GiB/project/month | JSON logs, no access logs |
| Cloud Monitoring | GKE system metrics | n/a | System metrics free | Google Managed Prometheus **disabled** (it bills per sample) |
| Workload Identity Federation, IAM, VPC, firewall, internal static IP | Security / networking | $0 | n/a | n/a |
| Budget (optional, `billing_account_id`) | Email alerts at 25/50/90% | $0 | n/a | Set a $25 budget on day one |

## 3. Session cost and project estimate

| Mode | What runs | Approx. cost per hour |
|---|---|---|
| **Paused** (§4.1) | Cloud SQL stopped (disk only), bucket, Firestore, AR images, Pub/Sub, function at zero | ≈ $0.002/h (≈ $1–2/month) |
| **Working** (2 Spot nodes) | GKE + Kafka + monitoring + 7 services + Cloud SQL + 2 LBs | ≈ $0.15/h |
| **Working, on-demand nodes** | same with on-demand nodes | ≈ $0.22/h |
| **+ Flink** | + Dataproc single node | + $0.09/h |
| **Load test** | autoscaler adds the 3rd node | + $0.07/h while scaled out |

Example plan: 40 h of cluster time (30 Spot + 10 on-demand) + 12 h of Dataproc + ~6 weeks paused ≈ 30×0.15 + 10×0.22 + 12×0.09 + 2 ≈ **$10**. Leave a margin for mistakes, such as forgetting to pause overnight (≈ $3.50 per night). Plan for **$10–25**.

## 4. Pause, resume, final cleanup (PowerShell)

### 4.1 Pause — end of every session
```powershell
.\scripts\teardown_k8s.ps1 -ProjectId $env:PROJECT_ID
terraform -chdir=infra/terraform/02-platform destroy -auto-approve
terraform -chdir=infra/terraform/01-foundation apply -auto-approve -var gke_enabled=false -var cloudsql_running=false -var dataproc_enabled=false
```
Why this order: the GKE Ingress (global LB), the Kafka internal LB and the PersistentVolumes are created by **Kubernetes controllers**, not by Terraform. If the cluster were deleted first, they could be **orphaned** and keep billing. `teardown_k8s.ps1` deletes them through Kubernetes, waits until none are left and prints any leftover forwarding rules and unattached disks (both lists must be empty).

What still exists while paused (≈ $1–2/month): Cloud SQL **stopped** (only its 10 GB HDD is billed), the buckets, Firestore data, Artifact Registry images, the Pub/Sub topic, the function (scaled to zero), service accounts.

### 4.2 Resume
```powershell
terraform -chdir=infra/terraform/01-foundation apply -auto-approve -var gke_enabled=true -var cloudsql_running=true
gcloud container clusters get-credentials s19-gke --zone us-central1-a --project $env:PROJECT_ID
terraform -chdir=infra/terraform/02-platform apply -auto-approve
```
Argo CD then redeploys everything from Git (5–12 minutes).

### 4.3 Final cleanup after grading
```powershell
.\scripts\teardown_k8s.ps1 -ProjectId $env:PROJECT_ID
terraform -chdir=infra/terraform/02-platform destroy -auto-approve
terraform -chdir=infra/terraform/01-foundation destroy -auto-approve
gcloud storage rm -r "gs://$($env:PROJECT_ID)-s19-tfstate"
terraform -chdir=infra/terraform/00-bootstrap destroy -auto-approve -var "project_id=$env:PROJECT_ID"
```
Verify (each should print `Listed 0 items.`):
```powershell
gcloud compute forwarding-rules list; gcloud compute addresses list; gcloud compute disks list; gcloud compute instances list
gcloud dataproc clusters list --region us-central1; gcloud sql instances list; gcloud container clusters list
```
Absolute stop: Console → **IAM & Admin → Settings → SHUT DOWN** (billing for the project stops immediately; deletion after 30 days). Note: a deleted Workload Identity pool id (`s19-github`) stays reserved for 30 days; if you redeploy into the same project within that time, undelete it (`gcloud iam workload-identity-pools undelete s19-github --location global`) and `terraform import` it.

## 5. Guardrails checklist

1. Create the **budget alert** (README 7.2) before the first billable apply.
2. **Pause (§4.1) at the end of every session.** Forgetting overnight costs ≈ $3.50.
3. Keep `dataproc_enabled = false` except for Flink work and the demo; the cluster auto-deletes after 2 hours only when **no job** is running, and a streaming job never finishes — delete it yourself.
4. `use_spot_nodes = true` while developing (cheaper, may be preempted), `false` on demo day.
5. Stay within the trial's 8 vCPU: 3 GKE nodes × 2 vCPU + Dataproc 2 vCPU = 8. Do not raise `gke_max_nodes`.
6. Check **Billing → Reports** (group by service) after each session.
7. Nothing in this repository creates paid resources by itself: billable resources appear only when **you** run the 💲 steps.
