# Testing report

Date: 18 November 2026. All results below were produced on the **final code in this ZIP**. Raw outputs are in [`docs/evidence/sandbox/`](evidence/sandbox/).

## 1. Test environment and its limits

The tests ran in an isolated Linux sandbox (Python 3.12.3, Node 22, OpenJDK 21, Docker CLI without a daemon). Its network allowed **PyPI and npm only**: Docker Hub, Maven Central, the Terraform registry, Google Cloud and Apache download sites were blocked. Consequences:

| Available | Used for |
|---|---|
| Real **PostgreSQL 16** (PyPI `pgserver`) | Resource Registry and Dispatch (Cloud SQL is PostgreSQL 15; the SQL used is identical in both versions) |
| **GCS emulator** (PyPI `gcp-storage-emulator`) | Incident Intake raw archive and attachments |
| **Flink 1.17.2** runtime jars (PyPI `apache-flink-libraries`) | the Flink pipeline on a real local MiniCluster |
| functions-framework 3.10.2 | the Alert Service runtime |
| PyPI validators (`kubernetes-validate`, `python-hcl2`, `yamllint`, `pyflakes`, tree-sitter PowerShell grammar) | static checks |

| **Not** available | Effect |
|---|---|
| Docker daemon / Docker Hub | no image builds, no `docker compose up` |
| Kafka broker | no Kafka round-trip (producer/consumer paths not executed) |
| Firestore and Pub/Sub emulators | Volunteer Coordination, Situation Analytics and the Firestore paths of the Alert Service not executed |
| Terraform binary + registry | no `terraform validate/plan` |
| Maven Central | Flink job's Kafka wiring (`SituationAnalyticsJob.java`) not compiled; `mvn package/test` not run |
| `pwsh` | PowerShell scripts parsed, not executed |
| GCP | nothing deployed (and nothing billable created) |

Services that could run were started as **native processes** with the same code and environment variables as the containers; a small reverse proxy reproduced the Ingress path routing on `:8080`.

## 2. Results

| # | Test | Command (from repo root) | Expected | Actual | Status |
|---|---|---|---|---|---|
| 1 | Pinned dependencies resolve | `pip install -r services/requirements.txt` (Python 3.12) | every pinned version installs | all 14 pins installed (fastapi 0.163.1 … google-cloud-pubsub 2.44.0) | ✅ PASS |
| 2 | gRPC code generation | `python scripts/gen_proto.py` | stubs generated | `generated stubs in …/s19common/pb` | ✅ PASS |
| 3 | Python syntax + lint | `python -m py_compile …`; `pyflakes services scripts tests` | no errors/warnings | 26 files compiled; pyflakes clean (2 unused imports were removed) | ✅ PASS |
| 4 | Dynamo unit/integration tests (3 real gRPC replicas) | `python -m pytest -v tests/` | 8 passed | **8 passed in 4.68 s** ([pytest.txt](evidence/sandbox/pytest.txt)) | ✅ PASS |
| 5 | Consistency suite through the gateway (quorum, failures, read repair, siblings + merge, quorum loss, W/R tuning, slow replica) | `BASE_URL=http://127.0.0.1:8080 ADMIN_TOKEN=local-admin-token python scripts/consistency_test.py` | 14/14 | **14/14 checks passed** ([consistency-test.txt](evidence/sandbox/consistency-test.txt)) | ✅ PASS |
| 6 | Real replica crash (SIGKILL) and recovery | `tools/crash_test.py` (sandbox harness, in the evidence file) | writes continue with 2 acks; restarted replica keeps old data; anti-entropy repairs the 5 missed keys | 5 writes with `acks: 2`; restarted replica had its 3 old keys, missed 5; anti-entropy `repaired: {incident-store-2: 5}`; 0 missing after | ✅ PASS ([crash-recovery.txt](evidence/sandbox/crash-recovery.txt)) |
| 7 | Dispatch rollback when the incident write misses its quorum (new) | coordinator with W=3, replica 2 down, `POST /api/dispatch` | 503; reservation released; dispatch `FAILED`; incident back to `REPORTED` after recovery | 503 `dispatch rolled back`; AVAILABLE 21 → 21; row `FAILED`; incident `REPORTED`, no resources, rollback note | ✅ PASS ([dispatch-compensation.txt](evidence/sandbox/dispatch-compensation.txt)) |
| 8 | Resource Registry on PostgreSQL: optimistic locking + `FOR UPDATE SKIP LOCKED` under 12 concurrent reservations | registry harness | stale PATCH → 409; no resource reserved twice; all released | PATCH 200 then stale 409; 22 reserved of 22, **0 duplicates**; 22 available after release | ✅ PASS ([registry-concurrency.txt](evidence/sandbox/registry-concurrency.txt)) |
| 9 | Schema migrations from an empty database | start registry + dispatch on a fresh DB | migrations applied once | `001_schema.sql`, `002_seed.sql` (registry), `001_schema.sql` (dispatch) applied; 105 resources seeded | ✅ PASS (service logs) |
| 10 | End-to-end check through one base URL (partial: no Firestore/Kafka/Pub/Sub) | `BASE_URL=http://127.0.0.1:8080 python scripts/e2e_check.py --alert-timeout 3` | all checks that do not need the missing services pass | **15/29**: every Intake, Coordinator, gRPC, GCS, Cloud SQL and Dispatch check passed; the 14 FAILs are exactly the checks needing Firestore, Kafka or Pub/Sub. The dispatch still succeeded with resources while the volunteer service was down (best-effort fix) | ⚠️ PARTIAL — expected ([e2e-check-partial.txt](evidence/sandbox/e2e-check-partial.txt)) |
| 11 | Functions Framework accepts the Pub/Sub emulator's push format (local Alert Service path) | POST a push body to functions-framework 3.10.2 | HTTP 200 and a `messagePublished` CloudEvent with the message id | HTTP 200; `type google.cloud.pubsub.topic.v1.messagePublished`, `messageId 123456`, payload decoded | ✅ PASS ([functions-framework-pubsub-push.txt](evidence/sandbox/functions-framework-pubsub-push.txt)) |
| 12 | Alert Service webhook channel (real HTTP POST) and channel selection | real `services/alert-function/main.py` against a local HTTP endpoint | DELIVERED to a live endpoint, FAILED (with error) to an unreachable one | DELIVERED with the alert body received; FAILED `Connection refused`; channels per severity as designed | ✅ PASS ([alert-webhook-channel.txt](evidence/sandbox/alert-webhook-channel.txt)) |
| 13 | Flink processing logic on a real Flink 1.17.2 MiniCluster: 1-minute tumbling event-time windows per region, unique reporters, out-of-order event, cross-window keyed-state surge detection | `PipelineScenario` (also wrapped as JUnit `SituationPipelineTest` for `mvn test`) | 13 checks | **13/13 PASS**, 4 window results ([flink-pipeline-minicluster.txt](evidence/sandbox/flink-pipeline-minicluster.txt)). Sandbox build only: Jackson import pointed at Flink's bundled copy | ✅ PASS |
| 14 | Kubernetes / GitOps manifests: kustomize-style render, schema validation, cross-references | `python scripts/validate/validate_manifests.py .` | all pass | **114 checks passed**; 28 rendered objects valid against Kubernetes 1.33 schemas; selectors, ports, HPA targets, Ingress backends, Argo CD paths verified ([k8s-manifest-validation.txt](evidence/sandbox/k8s-manifest-validation.txt)) | ✅ PASS (static) |
| 15 | Terraform: HCL parse + reference resolution | `python scripts/validate/validate_terraform.py .` | all pass | **29 checks passed**: 13 files parse; every `var.`, resource, data, local reference resolves; 02-platform reads only declared 01 outputs; referenced files exist ([terraform-static-checks.txt](evidence/sandbox/terraform-static-checks.txt)) | ✅ PASS (static) |
| 16 | YAML lint | `yamllint` (relaxed) on `deploy/ infra/ .github/ docker-compose.yml` | 0 errors | 0 errors | ✅ PASS |
| 17 | docker-compose files | `docker compose config --quiet` (default and `--profile flink`) | valid | valid, 22 services | ✅ PASS (static) |
| 18 | Shell scripts | `bash -n scripts/*.sh …` | no syntax errors | 8/8 OK | ✅ PASS |
| 19 | k6 scripts | `node --check` as ES modules | parse | 2/2 OK | ✅ PASS (syntax) |
| 20 | PowerShell scripts | tree-sitter PowerShell grammar | no parse errors | 8/8 OK | ✅ PASS (syntax only) |
| 21 | Flink `pom.xml`, Grafana dashboard JSON | XML/JSON parse | parse | pom well-formed; dashboard 38 panels; every metric name in the panels exists in the code or in the standard exporters | ✅ PASS (static) |

## 3. Defects found during testing and fixed

| Found by | Defect | Fix |
|---|---|---|
| e2e (#10) | `POST /api/dispatch/{id}/complete` failed with 503 when Volunteer Coordination was unreachable, after resources were already released, leaving the incident not RESOLVED | releases are best-effort and idempotent; the incident update still happens; response reports `resourcesReleased`/`volunteersReleased` |
| e2e (#10) | a dispatch aborted half-way (dependency down / quorum lost) left an `ACTIVE` dispatch row and reserved resources; the unique index then blocked any new dispatch for that incident | compensation: release, mark `FAILED`, plus a compensating incident write (test #7) |
| analysis + #7 | in a leaderless store a write that misses its quorum can still land on a minority of replicas, so the aborted `DISPATCHED` version could later spread via read repair | compensating version written with the failed write's vector clock (descends from it) |
| pyflakes (#3) | unused imports | removed |
| e2e script | crashed when no volunteer was assigned | guarded |

## 4. Not tested here — how to verify yourself

| Item | Why not here | Verify with (README) | Pass criterion |
|---|---|---|---|
| Docker image builds, `--target test` stage | no Docker daemon/Hub | 4.1, 9.2 | `8 passed`; 7 images pushed |
| Whole local stack incl. Kafka, Firestore/Pub/Sub emulators, nginx gateway, Alert Service | same | 5.1–5.6 | `29/29` from `e2e_check.py`, `14/14` consistency |
| Kafka producers/consumers (auto-dispatch, Flink in/out, analytics consumer) | no broker | 5.4 (8b), 11.3, 13.2, 13.5 | AUTO dispatch appears; events visible with the console consumer |
| Volunteer Coordination, Situation Analytics, Alert Service Firestore deliveries | no Firestore emulator | 5.4 (2, 5d, 6, 8c, 8d, 9), 13.1 | checks pass; Firestore collections populated |
| Flink job jar (Kafka source/sink), `mvn test` | Maven Central blocked | 4.3, 5.7, 13.4 | jar built, JUnit passes, job RUNNING, windows on `incident-aggregates` |
| `terraform validate / plan / apply` | registry blocked; no GCP | 8.4–8.6, 10.4 | `Success! The configuration is valid.`; plan 75 to add; apply completes |
| Argo CD sync, Helm charts (argo-cd 9.5.15, argocd-apps 2.0.4, kube-prometheus-stack 87.19.2 — versions confirmed to exist) | no cluster | 10.5–10.7 | all apps Synced/Healthy |
| GKE Ingress, Workload Identity, Cloud SQL private IP, Eventarc trigger | no GCP | 10.8, 11.2, 13.1 | `e2e_check.py` 29/29 against the Ingress IP |
| HPA scale-out under k6 | no GCP | 15.2 | replicas 1 → ≥3 for both HPAs |
| Prometheus targets, Grafana dashboard, Cloud Logging queries | no GCP | 14.1–14.3 | targets UP; panels show data; logs from all services, function and Dataproc |
| PowerShell execution | no `pwsh` | used throughout the README | each step's expected output |
| GitHub Actions workflow | no GitHub runner | 3.3, 9.4 | `test` green; `build-push` green after variables are set |

Record your own runs in `docs/evidence/` (README Part 16): those are the official evidence for grading.
