# Summary of files added, modified and removed

Compared with the ZIP you uploaded (`s19-disaster-management`). The topic, the 8 services, the architecture (GKE + Cloud SQL + Firestore + GCS + Pub/Sub + Cloud Run function + Flink on Dataproc + Argo CD + Prometheus/Grafana + Cloud Logging) and the Dynamo design are unchanged.

## Audit outcome

The uploaded project already covered requirements (a)–(h). The audit found these problems, all fixed:

| # | Problem | Severity | Fix |
|---|---|---|---|
| 1 | **Alert Service used a "simulated provider"**: it logged `DELIVERED` without delivering anything (a fabricated success, which you asked to remove) | high | real delivery channels: Firestore inbox per volunteer, regional broadcast, optional HTTPS webhook; status is `DELIVERED` only when the write/POST succeeded, otherwise `FAILED` with the error; new read endpoints in Volunteer Coordination |
| 2 | **Dispatch could leave half-finished state**: if the Registry, the Volunteer service or the incident quorum write failed after the dispatch row was inserted, the row stayed `ACTIVE` and resources stayed `RESERVED`; the unique index then blocked any new dispatch for the incident | high | best-effort reservations, compensation (release + `FAILED`), compensating incident write that supersedes a partially-applied Dynamo write; tested |
| 3 | Completing a dispatch failed if Volunteer Coordination was down, after resources were already released | medium | idempotent best-effort releases; incident still marked RESOLVED |
| 4 | **Not usable on Windows/PowerShell**: all helper scripts were bash, `gen_proto.sh` used GNU `sed -i`, the README used `make`/bash, and Git's CRLF conversion on Windows would break `bash` in the Docker build | high | PowerShell scripts for every operation, cross-platform `gen_proto.py`, `.gitattributes` forcing LF, tests runnable through Docker only (`--target test`), Flink jar built in a Maven container |
| 5 | Kafka consumers could miss a topic created after start-up for up to 5 minutes (librdkafka default metadata refresh) | medium | `topic.metadata.refresh.interval.ms=10000`; compose waits for topic creation |
| 6 | Local stack had no single entry point (each service on its own port) | low | nginx gateway on `localhost:8080` with the Ingress path routing; Kafka topic init; full Flink profile (build jar → cluster → submit) |
| 7 | Flink logic could not be tested without Kafka | medium | logic split into `SituationPipeline`, MiniCluster scenario + JUnit test |
| 8 | Budget resource could be created before its API was enabled | low | `depends_on` |
| 9 | Function build service account lacked the documented Cloud Build role; GKE node SA lacked the default node role | low | roles added |
| 10 | First CI push failed (red) until GCP variables existed | low | `build-push` skipped until `GCP_PROJECT_ID` is set |
| 11 | Unused imports | trivial | removed |
| 12 | The README was Linux-oriented and pointed to an 18-phase plan; old "evidence" came from an earlier session and could not be re-verified | high (for you) | new beginner README for Windows with expected outputs; new evidence produced and stored in `docs/evidence/sandbox/` |

## Added

| File | Purpose |
|---|---|
| `.gitattributes` | LF line endings for everything that runs in containers/CI; CRLF for `.ps1` |
| `local/nginx.conf` | local API gateway (same routes as the GKE Ingress) |
| `scripts/env.ps1` | loads `BASE_URL`/`ADMIN_TOKEN` (local or from Terraform outputs) and the `s19` API helper |
| `scripts/configure.ps1`, `set-image-tag.ps1`, `build_push.ps1`, `build_flink_jar.ps1`, `submit_flink_job.ps1`, `teardown_k8s.ps1`, `record_hpa.ps1` | Windows equivalents of every bash helper |
| `scripts/gen_proto.py` | cross-platform gRPC stub generator (used by Dockerfile, CI, tests) |
| `scripts/e2e_check.py` | 29 end-to-end checks of all services through one base URL (`--flink` adds the Flink check) |
| `scripts/validate/validate_manifests.py`, `validate_terraform.py`, `README.md` | offline validators for Kubernetes/GitOps manifests and Terraform |
| `tests/conftest.py` | generates gRPC stubs automatically before `pytest` |
| `flink/.../SituationPipeline.java` | the stream-processing logic, independent of Kafka |
| `flink/.../src/test/java/.../PipelineScenario.java`, `SituationPipelineTest.java` | Flink MiniCluster test (13 checks) |
| `docs/REQUIREMENTS_TRACEABILITY.md` | requirement → implementation → verification matrix |
| `docs/DEMO_GUIDE.md` | step-by-step final demonstration script |
| `docs/TESTING_REPORT.md` | test commands, expected vs actual results, limitations |
| `docs/COST_AND_CLEANUP.md` | costs, pause/resume, final cleanup (PowerShell) |
| `docs/CHANGES.md` | this file |
| `docs/evidence/sandbox/*.txt` | raw outputs of the tests in the testing report |

## Modified

| File | Change |
|---|---|
| `README.md` | rewritten: complete beginner guide for Windows 11 + PowerShell with expected outputs, from ZIP to demo and cleanup |
| `services/alert-function/main.py` | real delivery channels (inbox, broadcast, webhook), honest per-delivery status, `process_alert()` core |
| `services/dispatch/app/main.py` | best-effort dependencies, compensation + compensating quorum write, resilient completion, `alertPublished` in the response |
| `services/volunteer-coordination/app/main.py` | `GET /api/volunteers/{id}/notifications`, `GET /api/volunteers/broadcasts/{region}` |
| `services/incident-intake/app/main.py` | `kafkaEventQueued` in the response; unused import removed |
| `services/incident-store/app/server.py` | unused import removed |
| `services/common/s19common/kafka_util.py` | faster topic metadata refresh for consumers |
| `services/Dockerfile` | uses `gen_proto.py`; new `test` stage; explicit `runtime` stage (default) |
| `flink/.../SituationAnalyticsJob.java` | Kafka wiring only, uses `SituationPipeline`; `--starting-offsets`; `--checkpoint-dir jobmanager` for local runs |
| `flink/.../pom.xml` | JUnit 5 + Surefire (`mvn test`) |
| `docker-compose.yml` | gateway, Kafka healthcheck + topic init, admin token, startup ordering, full Flink profile, optional webhook |
| `infra/terraform/01-foundation/iam.tf` | `roles/cloudbuild.builds.builder` for the function build SA, `roles/container.defaultNodeServiceAccount` for nodes |
| `infra/terraform/01-foundation/function.tf`, `variables.tf`, `terraform.tfvars.example` | `alert_webhook_url` variable |
| `infra/terraform/01-foundation/data_stores.tf` | budget depends on the APIs |
| `.github/workflows/ci.yml` | `gen_proto.py`, pinned pytest, tests path filter, `build-push` skipped until variables exist |
| `scripts/gen_proto.sh`, `scripts/submit_flink_job.sh` | delegate to `gen_proto.py`; Maven-in-Docker fallback; `gcloud storage` |
| `scripts/consistency_test.py`, `loadtest/k6/*.js` | default base URL = gateway `http://localhost:8080` |
| `Makefile` | uses `gen_proto.py`, new `e2e` target (Linux/macOS convenience) |
| `docs/DESIGN.md` | alert channels, cross-service consistency (§4.3), delivery pipeline (§8), local vs cloud (§9), rationale rows |
| `task_divison.txt` | references to new files (names/IDs still for you to fill in) |

## Removed

| File | Reason |
|---|---|
| `docs/IMPLEMENTATION_PLAN.md` | Linux/bash-oriented; superseded by the new README (keeping both would give contradictory instructions) |
| `docs/DEMO_SCRIPT.md` | superseded by `docs/DEMO_GUIDE.md` |
| `docs/REQUIREMENTS_CHECKLIST.md` | superseded by `docs/REQUIREMENTS_TRACEABILITY.md` |
| `docs/COST_PLAN.md` | merged into `docs/COST_AND_CLEANUP.md` |
| `docs/evidence/consistency-test-local.txt` | produced by an earlier session and not reproducible here; replaced by freshly measured `docs/evidence/sandbox/consistency-test.txt` |
