# S19 Disaster Management on Google Cloud — beginner's guide (Windows 11 + PowerShell)

CS/SS G527 Cloud Computing assignment · Scenario **S19 Disaster Management** · Concept **Leaderless replication (Dynamo-style storage)** · Cloud **GCP**

This guide takes you from the ZIP file to a demonstrated, submitted assignment. It assumes you are new to cloud computing. Every step says **where** to run it, **what to type**, **what it does**, **what you should see**, **what to do if it fails**, and **what comes next**.

> **About the expected outputs.** Outputs marked *"(measured)"* were produced when this project was tested (see [docs/TESTING_REPORT.md](docs/TESTING_REPORT.md)). Every other expected output shows the *shape* you should see: IDs, IP addresses, timestamps and project names will differ on your machine. Compare the structure and the key values called out under **Check**, not every character.

> **💲 Money.** Steps marked **💲 BILLABLE** create Google Cloud resources that use your free-trial credit (or real money after the trial). Nothing billable is created until you run those steps yourself. Read [docs/COST_AND_CLEANUP.md](docs/COST_AND_CLEANUP.md) before Part 8, and always finish a working session with Part 17.1 (pause).

---

## Contents

| Part | What you do | Costs money? |
|---|---|---|
| [0](#part-0--what-you-are-building) | Understand what you are building | — |
| [1](#part-1--install-and-verify-the-prerequisites) | Install and verify the tools | free |
| [2](#part-2--extract-and-configure-the-project) | Extract and look around the project | free |
| [3](#part-3--create-the-github-repository-and-push-the-code) | Create the GitHub repository and push | free |
| [4](#part-4--build-and-test-locally) | Run the automated tests locally | free |
| [5](#part-5--start-and-verify-all-services-locally) | Run all 8 services on your laptop and verify them | free |
| [6](#part-6--set-up-google-cloud-console--powershell) | Google Cloud project, CLI login | free |
| [7](#part-7--billing-apis-iam-and-service-accounts) | Billing, budget alert, APIs, IAM | free |
| [8](#part-8--provision-the-infrastructure-with-terraform) | Terraform: network, GKE, Cloud SQL, Firestore, GCS, Pub/Sub, function… | 💲 |
| [9](#part-9--build-and-push-the-docker-images) | Build and push the 7 container images | 💲 (tiny) |
| [10](#part-10--configure-gke-and-deploy-through-gitops-argo-cd) | Install Argo CD; Git deploys everything | 💲 |
| [11](#part-11--verify-all-microservices-and-integrations) | Verify every service through the public URL | 💲 (running) |
| [12](#part-12--replication-quorum-failure-handling-and-recovery) | Dynamo concept: quorum, failures, repair | 💲 (running) |
| [13](#part-13--serverless-function-event-triggers-and-flink) | Serverless function, Kafka, Pub/Sub, Flink on Dataproc | 💲 |
| [14](#part-14--monitoring-logging-and-dashboards) | Prometheus, Grafana, Cloud Logging | 💲 (running) |
| [15](#part-15--load-test-and-autoscaling-hpa) | k6 load test, HPA scale-out | 💲 |
| [16](#part-16--collect-submission-evidence) | Screenshots and logs for submission | — |
| [17](#part-17--clean-up-safely-and-avoid-charges) | Pause between sessions, final cleanup | saves money |
| [18](#part-18--troubleshooting-index) | Troubleshooting index | — |

Other documents: [Design](docs/DESIGN.md) · [Requirement traceability](docs/REQUIREMENTS_TRACEABILITY.md) · [Final demo guide](docs/DEMO_GUIDE.md) · [Testing report](docs/TESTING_REPORT.md) · [Cost & cleanup](docs/COST_AND_CLEANUP.md) · [Changes](docs/CHANGES.md) · [task_divison.txt](task_divison.txt)

---

## Part 0 — What you are building

Eight microservices for disaster management. Citizens and field officers report incidents; the system stores every report in a **leaderless, Dynamo-style replicated store** that keeps working when replicas fail, dispatches vehicles/supplies/teams and volunteers, sends alerts and shows live analytics.

| # | Service | Runs on | Talks via | Stores data in |
|---|---|---|---|---|
| 1 | Incident Intake | GKE + **HPA** | REST in; REST → Coordinator; **Kafka** + **Pub/Sub** out | **Cloud Storage** |
| 2 | Resource Registry | GKE | REST | **Cloud SQL** (PostgreSQL) |
| 3 | Replicated Incident Store (3 replicas) | GKE StatefulSet | **gRPC** | own disk per replica |
| 4 | Quorum Coordinator | GKE + **HPA** | REST in, gRPC out, Kafka out | — (stateless) |
| 5 | Dispatch | GKE | REST, Kafka in/out, Pub/Sub out | Cloud SQL |
| 6 | Volunteer Coordination | GKE | REST | **Firestore** |
| 7 | Alert Service | **Cloud Run functions (serverless)** | Pub/Sub → Eventarc | Firestore |
| 8 | Situation Analytics | **Flink on Dataproc** + API on GKE | Kafka in/out, REST | Firestore |

How the assignment requirements (a)–(h) map to this: see [docs/REQUIREMENTS_TRACEABILITY.md](docs/REQUIREMENTS_TRACEABILITY.md). The architecture diagrams are in [docs/DESIGN.md](docs/DESIGN.md).

**Two environments, kept clearly apart:**

| | Local (Parts 4–5) | Google Cloud (Parts 6–17) |
|---|---|---|
| Runs on | Docker Desktop on your PC | GKE, Cloud SQL, Firestore, GCS, Pub/Sub, Cloud Run functions, Dataproc |
| Kafka | real Kafka container | real Kafka on GKE |
| Database | real PostgreSQL container | Cloud SQL |
| Firestore / Pub/Sub / GCS | official Google **emulators** / fake-gcs-server | the real services |
| Flink | Flink 1.17 containers | Flink 1.17 on Dataproc |
| Public URL | `http://localhost:8080` | `http://<INGRESS_IP>` |
| Cost | $0 | uses credit |

Local runs are for building and checking. The assignment is demonstrated on **Google Cloud**.

---

## Part 1 — Install and verify the prerequisites

Everything in this guide runs in **PowerShell 7** on Windows 11. Install the tools once.

### 1.1 Install PowerShell 7

- **Where:** Start menu → type `Terminal` → open **Terminal** (it starts Windows PowerShell 5.1 the first time).
- **Run:**
  ```powershell
  winget install --id Microsoft.PowerShell --source winget
  ```
- **What it does:** installs PowerShell 7 next to the built-in Windows PowerShell 5.1. The helper scripts in this project use PowerShell 7 features.
- **Expected output:** the last line reads `Successfully installed`.
- **Check:** close Terminal, reopen it, click the **˅** arrow next to the tab → **PowerShell** (the black icon, *not* "Windows PowerShell"). Then run `$PSVersionTable.PSVersion`. Expected:
  ```
  Major  Minor  Patch  PreReleaseLabel BuildLabel
  -----  -----  -----  --------------- ----------
  7      4      x
  ```
  Any version **7.4 or newer** is fine.
- **If it fails:** `winget` not found → open Microsoft Store, update **App Installer**, retry.
- **Tip:** Terminal → Settings → Startup → Default profile → **PowerShell** so new tabs open PowerShell 7.
- **Next:** 1.2.

### 1.2 Allow local scripts to run

- **Where:** PowerShell 7.
- **Run:**
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
  Get-ExecutionPolicy -List
  ```
- **What it does:** lets you run the `.ps1` scripts in this project (scripts downloaded from the internet still need to be unblocked, see 2.1).
- **Expected output:** the `CurrentUser` row shows `RemoteSigned`.
- **Next:** 1.3.

### 1.3 Install the tools

- **Where:** PowerShell 7 (normal, not administrator).
- **Run** (one line at a time; each takes 1–5 minutes):
  ```powershell
  winget install --id Git.Git --source winget
  winget install --id Docker.DockerDesktop --source winget
  winget install --id Python.Python.3.12 --source winget
  winget install --id Google.CloudSDK --source winget
  winget install --id Hashicorp.Terraform --source winget
  winget install k6 --source winget
  ```
- **What it does:** installs Git, Docker Desktop, Python 3.12, the Google Cloud CLI (`gcloud`), Terraform and k6 (load testing).
- **You do NOT need:** Java, Maven, Helm or a Linux machine. The Flink job is compiled inside a Docker container, and Terraform installs Helm charts itself.
- **Expected output:** `Successfully installed` for each package (or `Found an existing package already installed`).
- **If it fails:** a UAC prompt may appear: click **Yes**. If a package ID is not found, run `winget search <name>` and use the ID shown.
- **Next:** **close every Terminal window and open a new PowerShell 7 tab** so the new `PATH` is loaded, then 1.4.

### 1.4 Start Docker Desktop

- **Where:** Start menu → **Docker Desktop**.
- **What to do:** accept the licence, choose **Use WSL 2** (recommended) when asked, and let it finish. If Windows asks to install or update WSL, allow it and **restart** the PC.
- **Settings to check:** Docker Desktop → ⚙ **Settings** → **Resources** → give it at least **6 GB memory** (the full local stack runs ~20 containers). Click **Apply & restart**.
- **Check** in PowerShell:
  ```powershell
  docker version --format "client {{.Client.Version}} / server {{.Server.Version}}"
  docker run --rm hello-world
  ```
  Expected:
  ```
  client 28.x.x / server 28.x.x
  ...
  Hello from Docker!
  This message shows that your installation appears to be working correctly.
  ```
- **If it fails:** `error during connect ... pipe/dockerDesktopLinuxEngine` → Docker Desktop is not running; start it and wait until the whale icon in the taskbar stops animating.
- **Next:** 1.5.

### 1.5 Add kubectl and the GKE auth plugin to gcloud

- **Where:** PowerShell 7. If the command complains about permissions, open PowerShell **as Administrator** (right-click → Run as administrator) for this one step.
- **Run:**
  ```powershell
  gcloud components install kubectl gke-gcloud-auth-plugin --quiet
  ```
- **What it does:** `kubectl` talks to Kubernetes; `gke-gcloud-auth-plugin` lets it log in to GKE with your Google account.
- **Expected output:** ends with `Update done!`.
- **Next:** 1.6.

### 1.6 Verify every tool

- **Where:** a **new** PowerShell 7 tab.
- **Run:**
  ```powershell
  git --version; docker --version; python --version; gcloud --version | Select-Object -First 1
  terraform version | Select-Object -First 1; kubectl version --client; k6 version
  gke-gcloud-auth-plugin --version
  ```
- **Expected output** (versions equal or newer):

  | Tool | Minimum | Example line |
  |---|---|---|
  | Git | 2.40 | `git version 2.47.1.windows.1` |
  | Docker | 24 | `Docker version 28.x.x, build ...` |
  | Python | **3.12.x** | `Python 3.12.10` |
  | Google Cloud CLI | 500 | `Google Cloud SDK 5xx.0.0` |
  | Terraform | **1.6** | `Terraform v1.13.x` |
  | kubectl | 1.30 | `Client Version: v1.3x.x` |
  | k6 | 0.50 | `k6 v1.x.x (...)` |
  | gke-gcloud-auth-plugin | any | `Kubernetes v1.3x...` |

- **If it fails:**
  - `python` opens the Microsoft Store → Settings → Apps → Advanced app settings → **App execution aliases** → turn **off** `python.exe` and `python3.exe`, then open a new tab.
  - `'terraform' is not recognized` → open a new tab (PATH refresh). Still missing → `winget install --id Hashicorp.Terraform --source winget` again.
- **Next:** 1.7.

### 1.7 Configure Git (once)

- **Where:** PowerShell 7.
- **Run** (use your own name and the email of your GitHub account):
  ```powershell
  git config --global user.name  "Your Name"
  git config --global user.email "you@example.com"
  git config --global core.autocrlf false
  git config --global init.defaultBranch main
  ```
- **What it does:** labels your commits; `core.autocrlf false` keeps Linux line endings in shell scripts (the repo also enforces this with `.gitattributes`). A shell script with Windows line endings would break the Docker build.
- **Next:** Part 2.

---

## Part 2 — Extract and configure the project

### 2.1 Extract the ZIP

- **Where:** File Explorer.
- **What to do:**
  1. Right-click the ZIP → **Properties** → if there is an **Unblock** checkbox at the bottom, tick it → **OK**. (Otherwise Windows marks every `.ps1` inside as "from the internet".)
  2. Right-click → **Extract All…** → choose `C:\dev` → **Extract**. Use a short path **without spaces**.
- **Check** in PowerShell:
  ```powershell
  cd C:\dev\s19-disaster-management
  Get-ChildItem -Name
  ```
  Expected (order may differ):
  ```
  .github
  deploy
  docs
  flink
  infra
  loadtest
  local
  proto
  scripts
  services
  tests
  .gitattributes
  .gitignore
  docker-compose.yml
  Makefile
  README.md
  task_divison.txt
  ```
- **If it fails:** if you see one more folder level (`C:\dev\s19-disaster-management\s19-disaster-management`), `cd` one level deeper. If scripts later say "is not digitally signed", run `Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File` in the project folder.
- **Next:** 2.2.

> From here on, **every PowerShell command runs in `C:\dev\s19-disaster-management`** unless the step says otherwise.

### 2.2 Find your way around

| Folder | Contents |
|---|---|
| `services/` | the Python microservices (one shared `Dockerfile`), shared library `services/common`, the serverless `alert-function` |
| `proto/` | the gRPC contract between the Quorum Coordinator and the replicas |
| `flink/situation-analytics-flink/` | the Flink job (Java, Maven) |
| `infra/terraform/` | `00-bootstrap` (state bucket), `01-foundation` (all cloud infrastructure), `02-platform` (Argo CD + cluster plumbing) |
| `deploy/argocd/apps/` | Argo CD applications (GitOps) |
| `deploy/k8s/` | Kubernetes manifests of the 7 containerised services, HPA, Ingress |
| `deploy/platform/` | Kafka and monitoring (Prometheus/Grafana) manifests and values |
| `scripts/` | PowerShell (`*.ps1`) and Python helpers; `*.sh` equivalents for Linux/CI |
| `tests/` | automated tests of the Dynamo layer |
| `loadtest/k6/` | load tests |
| `docs/` | design, traceability, demo guide, testing report, cost guide |

### 2.3 Edit `task_divison.txt`

- **Where:** any text editor (Notepad, VS Code).
- **What to do:** replace `<ID NUMBER n>` and `<NAME n>` with your group's ID numbers and names. Keep the task split, or swap rows if your group divided the work differently. This file is a required deliverable.
- **Next:** Part 3.

---

## Part 3 — Create the GitHub repository and push the code

Argo CD (Part 10) deploys **from this GitHub repository**, so it must exist before the cloud deployment.

### 3.1 Create an empty repository

- **Where:** browser → <https://github.com/new>.
- **What to enter:**
  - **Repository name:** `s19-disaster-management`
  - **Visibility:** **Public** (simplest: Argo CD can read it without a token). Private works too; see 10.3.
  - Leave **Add a README**, **.gitignore** and **license** **unticked** (the repo must be empty).
  - Click **Create repository**.
- **Expected result:** a page titled *Quick setup* showing a URL like `https://github.com/<your-user>/s19-disaster-management.git`. Copy it.
- **Next:** 3.2.

### 3.2 Push the code

- **Where:** PowerShell 7 in the project folder.
- **Run** (replace `<your-user>`):
  ```powershell
  git init
  git add -A
  git commit -m "S19 disaster management - initial import"
  git remote add origin https://github.com/<your-user>/s19-disaster-management.git
  git push -u origin main
  ```
- **What it does:** creates a local Git repository, commits every file and uploads it.
- **Expected output:** the first push opens a browser window to sign in to GitHub (Git Credential Manager). Then:
  ```
  Enumerating objects: ..., done.
  ...
  To https://github.com/<your-user>/s19-disaster-management.git
   * [new branch]      main -> main
  branch 'main' set up to track 'origin/main'.
  ```
- **Check:** refresh the GitHub page: you see the folders and this README rendered.
- **If it fails:** `src refspec main does not match any` → the commit did not happen; check `git status` and the `git config user.*` values from 1.7. `Authentication failed` → run `git credential-manager github login` (or sign in when the browser opens).
- **Next:** 3.3.

### 3.3 Check that CI ran

- **Where:** browser → your repo → **Actions** tab.
- **Expected result:** a workflow run named **ci** with a green ✔ on the `test` job (the Dynamo tests ran on GitHub's servers). The `build-push` job shows as **skipped**: it starts working after Part 9.4, when you add the GCP variables.
- **If it fails:** open the red run → `test` → read the failing step. A failure here means the same test fails locally in Part 4; fix it there first.
- **Next:** Part 4.

---

## Part 4 — Build and test locally

### 4.1 Run the Dynamo test-suite in Docker (no Python setup needed)

- **Where:** PowerShell 7, Docker Desktop running.
- **Run:**
  ```powershell
  docker build -f services/Dockerfile --target test --progress plain -t s19-tests .
  ```
- **What it does:** builds the shared Python image, generates the gRPC code from `proto/incident_store.proto` and runs `tests/test_dynamo.py`: three real gRPC replica servers plus the quorum engine, covering quorum reads/writes, a replica going down and being repaired by anti-entropy, read repair after silently dropped writes, concurrent writes creating siblings that are merged, quorum loss, and a slow replica.
- **Expected output** (the first build downloads ~200 MB and takes 3–6 minutes; the test lines are *(measured)*):
  ```
  #NN [test 6/6] RUN python /src/scripts/gen_proto.py /src && python -m pytest -q -p no:cacheprovider tests/
  #NN 1.2 generated stubs in /src/services/common/s19common/pb
  #NN 6.0 ........                                                                 [100%]
  #NN 6.0 8 passed in 4.68s
  ...
  #NN naming to docker.io/library/s19-tests done
  ```
- **Check:** `8 passed`. Any `F` or `failed` means a test failed; the lines above it say which.
- **If it fails:** `failed to solve: python:3.12-slim: ... TLS handshake timeout` → network/proxy issue, retry. `bash\r: No such file or directory` → the files have Windows line endings: re-extract the ZIP and keep `core.autocrlf false` (1.7).
- **Next:** 4.2.

### 4.2 (Optional) Run the same tests with Python on Windows

- **Where:** PowerShell 7.
- **Run:**
  ```powershell
  python -m venv .venv
  .\.venv\Scripts\Activate.ps1
  python -m pip install -r services/requirements.txt pytest==9.2.0 httpx
  python -m pytest -q tests
  ```
- **What it does:** creates a private Python environment, installs the same pinned libraries as the containers, auto-generates the gRPC stubs (`tests/conftest.py`) and runs the tests.
- **Expected output:** `8 passed in ...s` *(measured: `8 passed in 4.68s`)*.
- **Note:** keep this `.venv` activated whenever you run `python scripts\...` later (prompt starts with `(.venv)`). Reactivate in a new tab with `.\.venv\Scripts\Activate.ps1`.
- **If it fails:** `grpcio` build errors → you are not on Python 3.12 (`python --version`); recreate the venv with `py -3.12 -m venv .venv`.
- **Next:** 4.3.

### 4.3 Build and test the Flink job (inside Docker)

- **Where:** PowerShell 7.
- **Run:**
  ```powershell
  .\scripts\build_flink_jar.ps1 -RunTests
  ```
- **What it does:** runs Maven in the official `maven:3.9.9-eclipse-temurin-11` image: compiles the job, runs `SituationPipelineTest` (the real pipeline on a local Flink MiniCluster: 1-minute tumbling windows per region, unique-reporter counting, keyed-state surge detection, an out-of-order event), and builds the fat jar.
- **Expected output** (first run downloads Maven dependencies, 3–8 minutes):
  ```
  RESULT {"region":"north","windowStart":1700000040000,...,"incidents":2,...,"uniqueReporters":1,...,"surge":false,...}
  ...
  [PASS] north B: SURGE detected (6 >= 5 and 6 >= 2 x 2)
  ...
  Name                                 Length LastWriteTime
  ----                                 ------ -------------
  situation-analytics-flink-1.0.0.jar  ~6-9MB  18-11-2026 14:05:12
  ```
  The pipeline checks are *(measured)*; see [docs/evidence/sandbox/flink-pipeline-minicluster.txt](docs/evidence/sandbox/flink-pipeline-minicluster.txt).
- **Check:** 13 `[PASS]` lines, no `[FAIL]`, and the jar exists.
- **If it fails:** `Tests run: 1, Failures: 1` → read the `[FAIL]` line above it. Docker volume errors → make sure the project is on a local drive (C:), not OneDrive.
- **Next:** Part 5.

---

## Part 5 — Start and verify all services locally

This runs **all 8 services** plus Kafka, PostgreSQL, the Firestore and Pub/Sub emulators and a GCS emulator on your PC. No cloud account is used.

### 5.1 Start the stack

- **Where:** PowerShell 7, Docker Desktop running.
- **Run:**
  ```powershell
  docker compose up --build -d
  ```
- **What it does:** builds the 7 service images and starts ~19 containers. The first run downloads ~2–3 GB (emulator images are large) and takes 5–15 minutes.
- **Expected output** (last lines):
  ```
   ✔ Container s19-kafka-1                   Healthy
   ✔ Container s19-postgres-1                Healthy
   ✔ Container s19-incident-store-0-1        Started
   ...
   ✔ Container s19-gateway-1                 Started
   ✔ Container s19-pubsub-init-1             Healthy
  ```
- **Next:** 5.2.

### 5.2 Check that everything is running

- **Where:** PowerShell 7.
- **Run:**
  ```powershell
  docker compose ps --format "table {{.Service}}\t{{.State}}\t{{.Status}}"
  docker compose logs pubsub-init kafka-init
  ```
- **Expected output:**
  ```
  SERVICE                  STATE     STATUS
  alert-service            running   Up 2 minutes
  dispatch                 running   Up 2 minutes
  fake-gcs                 running   Up 2 minutes
  firestore                running   Up 2 minutes
  gateway                  running   Up 2 minutes
  incident-intake          running   Up 2 minutes
  incident-store-0         running   Up 2 minutes
  incident-store-1         running   Up 2 minutes
  incident-store-2         running   Up 2 minutes
  kafka                    running   Up 2 minutes (healthy)
  postgres                 running   Up 2 minutes (healthy)
  pubsub                   running   Up 2 minutes (healthy)
  pubsub-init              running   Up 2 minutes (healthy)
  quorum-coordinator       running   Up 2 minutes
  resource-registry        running   Up 2 minutes
  situation-analytics      running   Up 2 minutes
  volunteer-coordination   running   Up 2 minutes
  ```
  and in the logs: `pubsub emulator initialised: projects/s19-local/topics/alert-requests -> projects/s19-local/subscriptions/alert-service-push -> http://alert-service:8080/ (created: topic, subscription)` and the four topics `consistency-events`, `dispatch-events`, `incident-aggregates`, `incident-events`.
- **Check:** no service in state `restarting` or `exited`, and `pubsub` + `pubsub-init` show `(healthy)`. `kafka-init` exits by design once the topics exist and is not listed by `ps`. `pubsub-init` keeps running: the Pub/Sub emulator holds topics in memory only, so it re-creates the topic and the push subscription whenever the emulator restarts.
- **If it fails:** `docker compose logs <service> --tail 50` shows why. Typical first-run cause: `resource-registry`/`dispatch` started before Postgres was ready → `docker compose restart resource-registry dispatch`. Port already in use (`bind: address already in use` for 8080/5432/9094) → stop the program using it, or change the left side of `ports:` in `docker-compose.yml`.
- **Next:** 5.3.

### 5.3 Load the helper and call the API

- **Where:** PowerShell 7.
- **Run:**
  ```powershell
  . .\scripts\env.ps1 -Local
  s19 GET /api/quorum/config
  s19 GET /api/quorum/replicas
  ```
- **What it does:** the leading `. ` (dot + space) loads `env.ps1` into your session. It sets `$env:BASE_URL=http://localhost:8080` (the local gateway, routed exactly like the cloud Ingress) and defines the `s19` command, which calls the API and prints the HTTP status and JSON.
- **Expected output:**
  ```
  S19 API base : http://localhost:8080
  Admin token  : set
  Try          : s19 GET /api/quorum/config
  HTTP 200  GET /api/quorum/config
  {
    "n": 3,
    "w": 2,
    "r": 2,
    "rPlusWGreaterThanN": true,
    "replicas": { "incident-store-0": "incident-store-0:50051", ... },
    "rpcTimeoutMs": 800,
    "antiEntropyIntervalS": 30
  }
  HTTP 200  GET /api/quorum/replicas
  { "replicas": [ { "id": "incident-store-0", "reachable": true, "faultMode": "none", "keys": 0, ... }, ... ] }
  ```
- **Check:** `n` = 3, `w` = 2, `r` = 2, and all three replicas `"reachable": true`.
- **If it fails:** `The term 's19' is not recognized` → you forgot the leading `. ` in the first command. `HTTP 502` → the target service is still starting; wait 20 s.
- **Next:** 5.4.

### 5.4 Run the end-to-end check (all services, all mechanisms)

- **Where:** PowerShell 7 with `.venv` active (4.2) — or install the one library globally: `python -m pip install httpx`.
- **Run:**
  ```powershell
  python scripts/e2e_check.py
  ```
- **What it does:** exercises every service through the gateway: seeds volunteers, reports an incident (quorum write), reads it back (quorum read), updates it, uploads an attachment to the GCS emulator, dispatches it (Cloud SQL reservation + Firestore volunteer assignment + quorum write), waits for the Alert Service (Pub/Sub → function → Firestore inbox), completes the dispatch, reports a CRITICAL incident (Pub/Sub alert + **Kafka auto-dispatch**) and reads the analytics summary.
- **Expected output:**
  ```
  # e2e check against http://localhost:8080  (...)
  [PASS] 1. Quorum Coordinator reachable: GET /api/quorum/config -> 200
  ...
  [PASS] 5. POST /api/dispatch -> 201 (resources reserved in Cloud SQL, volunteers in Firestore)
  ...
  [PASS] 8b. Dispatch auto-dispatched it from the Kafka incident-events topic
  ...
  29/29 checks passed
  ```
- **Check:** the last line says `29/29 checks passed`. Each `[PASS]`/`[FAIL]` line is followed by the evidence it looked at.
- **If it fails:** the evidence line says what was seen. Common local causes:
  - `3.`/`5.` show `"alertPublished": false` and `6.`/`8.`/`8c.` fail → the Pub/Sub topic is missing: `docker compose ps pubsub pubsub-init` (both must be `healthy`) and `docker compose logs pubsub-init --tail 20`. `docker compose logs incident-intake | Select-String "pubsub publish failed"` shows the publish error.
  - `8b.` auto-dispatch fails → `docker compose logs dispatch | Select-String kafka`; Kafka may still be starting — rerun the script.
  - `1. Volunteer Coordination` 500 → the Firestore emulator is still starting (it takes ~30 s); retry.
- **Next:** 5.5.

### 5.5 Run the Dynamo consistency suite locally

- **Run:**
  ```powershell
  python scripts/consistency_test.py
  ```
- **What it does:** 14 checks of the leaderless store through the public API: quorum writes/reads, a replica DOWN, anti-entropy repair, read repair after silently dropped writes, concurrent writes → siblings → semantic merge, quorum loss with W=2 vs W=1, R=2 failure, convergence, slow replica.
- **Expected output** *(measured)*:
  ```
  [PASS] 1. Configuration N=3, W=2, R=2 satisfies R+W>N
  [PASS] 2. Quorum write (W=2) acknowledged
  ...
  [PASS] 7. A slow replica (2 s) does not block W=2 writes

  14/14 checks passed
  ```
- **If it fails:** `401 missing or wrong X-Admin-Token` → you did not load `env.ps1 -Local` in this tab (it sets `ADMIN_TOKEN=local-admin-token`).
- **Next:** 5.6.

### 5.6 Real crash and recovery of a replica (local)

- **Run:**
  ```powershell
  docker compose kill incident-store-2
  s19 GET /api/quorum/replicas
  s19 POST /api/incidents @{reporterId='crash-demo'; type='FIRE'; severity='MEDIUM'; region='east'; description='written while replica 2 is dead'; latitude=22.5; longitude=88.3}
  docker compose start incident-store-2
  Start-Sleep 5
  s19 POST /api/quorum/anti-entropy -Admin
  ```
- **Expected output:** `replicas` shows `incident-store-2` with `"reachable": false`; the incident is still created (`HTTP 201`, `"acks": 2`, replica 2 `"error: UNAVAILABLE ..."`); after the restart the anti-entropy result shows `"repaired": { "incident-store-2": 1 }` (or more). The same scenario was measured on real processes: [docs/evidence/sandbox/crash-recovery.txt](docs/evidence/sandbox/crash-recovery.txt).
- **Next:** 5.7.

### 5.7 (Optional) Run the real Flink job locally

- **Run:**
  ```powershell
  docker compose --profile flink up --build -d
  docker compose logs flink-job-submit
  ```
- **What it does:** builds the jar with Maven in Docker, starts a Flink 1.17 JobManager + TaskManager and submits the job reading the local Kafka topics.
- **Expected output:** `Job has been submitted with JobID 3f1c...`. Open <http://localhost:8081> → **Running Jobs** → `s19-situation-analytics` with status **RUNNING**.
- **Check the results:** create a few incidents (5.4 does that), wait **~2 minutes** (a 1-minute window closes once the watermark passes it), then:
  ```powershell
  s19 GET "/api/analytics/windows?limit=5"
  python scripts/e2e_check.py --flink
  ```
  Expected: items like `{"region":"west","windowStart":...,"incidents":1,"uniqueReporters":1,"surge":false,...}` and the last e2e check `[PASS] 9b. Flink window results arrived`.
- **Next:** 5.8.

### 5.8 Stop the local stack

- **Run:** `docker compose --profile flink down -v`
- **What it does:** stops every container and deletes local data volumes. Run `docker compose up -d` again any time.
- **Next:** Part 6 (cloud).

---
## Part 6 — Set up Google Cloud (Console + PowerShell)

### 6.1 Sign in and check your credit

- **Where:** browser → <https://console.cloud.google.com>.
- **What to do:** sign in with the Google account that has the free credits. Click **☰ (Navigation menu)** → **Billing** → **Overview**.
- **Expected result:** a **Free trial credit** (or **Credits**) card showing the remaining amount and the end date.
- **If it fails:** "You don't have any billing accounts" → click **Start free** / **Activate** at the top of the console and follow the sign-up (a card is required for identity verification; the trial does not charge it unless you upgrade).
- **Next:** 6.2.

### 6.2 Create the project

- **Where:** Console → project picker (top bar, left of the search box) → **NEW PROJECT**.
- **What to enter:**
  - **Project name:** `s19-disaster`
  - **Project ID:** click **EDIT** and choose a globally unique id of 6–30 lowercase letters/digits/hyphens, e.g. `s19-disaster-471203`. **Write it down: this is your `PROJECT_ID`.**
  - **Location:** *No organization* (or your university organization if you have one).
  - Click **CREATE**.
- **Expected result:** a notification "Create Project: s19-disaster" ✔. Select the new project in the project picker.
- **CLI alternative:** `gcloud projects create s19-disaster-471203 --name "s19-disaster"`.
- **Next:** 6.3.

### 6.3 Remember the project id in PowerShell

- **Where:** PowerShell 7.
- **Run** (your id):
  ```powershell
  [Environment]::SetEnvironmentVariable("PROJECT_ID", "s19-disaster-471203", "User")
  $env:PROJECT_ID = "s19-disaster-471203"
  $env:PROJECT_ID
  ```
- **What it does:** stores `PROJECT_ID` for every future PowerShell window and sets it in the current one. All later commands use `$env:PROJECT_ID`.
- **Expected output:** `s19-disaster-471203`.
- **Next:** 6.4.

### 6.4 Log the CLI in (two logins)

- **Where:** PowerShell 7.
- **Run:**
  ```powershell
  gcloud auth login
  gcloud config set project $env:PROJECT_ID
  gcloud config set compute/region us-central1
  gcloud config set compute/zone us-central1-a
  gcloud auth application-default login
  gcloud auth application-default set-quota-project $env:PROJECT_ID
  ```
- **What it does:** `gcloud auth login` lets *you* run `gcloud` commands; `application-default login` gives *Terraform* your credentials (stored only on your PC; no service-account key file is ever created).
- **Expected output:** two browser sign-ins; then `Updated property [core/project].` and finally `Credentials saved to file: [C:\Users\<you>\AppData\Roaming\gcloud\application_default_credentials.json]` and `Quota project "s19-disaster-471203" was added to ADC`.
- **Check:** `gcloud config list` shows `account = <your email>` and `project = <your id>`.
- **If it fails:** `set-quota-project` says the project has no Service Usage API → do 7.3 first, then rerun the last line.
- **Next:** Part 7.

---

## Part 7 — Billing, APIs, IAM and service accounts

### 7.1 Link billing to the project

- **Where:** Console → ☰ → **Billing** → **Account management** → tab **My projects** → row `s19-disaster-…` → **⋮ Actions** → **Change billing** → select your billing account (e.g. *My Billing Account*) → **SET ACCOUNT**.
- **CLI alternative:**
  ```powershell
  gcloud billing accounts list
  gcloud billing projects link $env:PROJECT_ID --billing-account 0X0X0X-0X0X0X-0X0X0X
  ```
- **Check:**
  ```powershell
  gcloud billing projects describe $env:PROJECT_ID --format "value(billingEnabled)"
  ```
  Expected: `True`.
- **Next:** 7.2.

### 7.2 Create a budget alert (strongly recommended)

- **Where:** Console → ☰ → **Billing** → **Budgets & alerts** → **CREATE BUDGET**.
- **What to enter:** Name `s19-cc-assignment`; **Projects:** your project; **Amount:** Specified amount `25` (USD/INR equivalent); thresholds **25 %, 50 %, 90 %**; tick **Email alerts to billing admins** → **FINISH**.
- **What it does:** emails you when spending (including credit usage) crosses each threshold. It does **not** stop resources; Part 17 does.
- **Next:** 7.3.

### 7.3 Enable the bootstrap APIs

- **Where:** PowerShell 7.
- **Run:**
  ```powershell
  gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com storage.googleapis.com --project $env:PROJECT_ID
  ```
- **What it does:** turns on the four APIs Terraform needs before it can enable the other 16 itself (`infra/terraform/01-foundation/apis.tf`).
- **Expected output:** `Operation "operations/acf.p2-..." finished successfully.` (or nothing if already enabled).
- **Console view:** ☰ → **APIs & Services** → **Enabled APIs & services** lists them.
- **Next:** 7.4.

### 7.4 IAM: who is allowed to do what

- **Your account:** as the project creator you are **Owner**. Check: Console → ☰ → **IAM & Admin** → **IAM** → your email with role **Owner**.
- **Service accounts Terraform will create** (least privilege, no key files):

  | Service account | Used by | Roles |
  |---|---|---|
  | `s19-gke-nodes` | GKE node VMs | log writer, metric writer, monitoring viewer, Artifact Registry reader, default node SA role |
  | `s19-workload` | the 7 pods (via **Workload Identity**: Kubernetes SA `s19/s19-app` → this GSA) | Firestore user, Pub/Sub publisher, object admin on the data bucket |
  | `s19-alert-fn` | the serverless Alert Service | Firestore user, log writer |
  | `s19-eventarc` | Eventarc trigger (Pub/Sub → function) | Eventarc event receiver, Cloud Run invoker |
  | `s19-fn-build` | Cloud Build for the function | Cloud Build builder, log writer, Artifact Registry writer, object viewer |
  | `s19-dataproc` | Dataproc (Flink) VM | Dataproc worker, log writer, metric writer, object admin on the data bucket |
  | `s19-ci` | GitHub Actions (via **Workload Identity Federation**, keyless) | Artifact Registry writer on repo `s19` only |

- **Secrets:** the Cloud SQL password, the admin token (protects fault injection) and the Grafana password are generated by Terraform (`random_password`), kept in Terraform state (a private bucket) and written to Kubernetes Secrets. Nothing secret is committed to Git: `terraform.tfvars` and `*.tfstate` are in `.gitignore`. **Never commit those files or paste their contents into screenshots.**
- **Next:** Part 8.

---

## Part 8 — Provision the infrastructure with Terraform

All cloud infrastructure is created by Terraform (requirement a). There are three stacks, applied in order: `00-bootstrap` → `01-foundation` → `02-platform` (Part 10).

### 8.1 Create the Terraform state bucket (💲 cents/month)

- **Where:** PowerShell 7, project folder.
- **Run:**
  ```powershell
  terraform -chdir=infra/terraform/00-bootstrap init
  terraform -chdir=infra/terraform/00-bootstrap apply -var "project_id=$env:PROJECT_ID"
  ```
  Type `yes` when asked.
- **What it does:** creates the versioned bucket `<PROJECT_ID>-s19-tfstate` that stores the state of the other two stacks. This stack keeps its own state in `infra/terraform/00-bootstrap/terraform.tfstate` on your PC (git-ignored); keep that file.
- **Expected output:**
  ```
  Terraform has been successfully initialized!
  ...
  Plan: 2 to add, 0 to change, 0 to destroy.
  ...
  Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

  Outputs:

  tfstate_bucket = "s19-disaster-471203-s19-tfstate"
  ```
- **If it fails:** `Error 409: Your previous request to create the named bucket succeeded and you already own it` → already created; run `terraform -chdir=infra/terraform/00-bootstrap import google_storage_bucket.tfstate "$($env:PROJECT_ID)-s19-tfstate"`. `oauth2: cannot fetch token` → redo the `application-default login` in 6.4.
- **Next:** 8.2.

### 8.2 Fill in the foundation variables

- **Run:**
  ```powershell
  Copy-Item infra/terraform/01-foundation/terraform.tfvars.example infra/terraform/01-foundation/terraform.tfvars
  notepad infra/terraform/01-foundation/terraform.tfvars
  ```
- **What to enter:**
  ```hcl
  project_id  = "s19-disaster-471203"                  # your PROJECT_ID
  github_repo = "<your-user>/s19-disaster-management"   # owner/name, NOT the full URL

  gke_enabled      = true
  cloudsql_running = true
  dataproc_enabled = false   # Flink cluster later, in Part 13
  use_spot_nodes   = true    # cheaper while developing; set false on demo day
  ```
  Optional: `alert_webhook_url = "https://ntfy.sh/<a-long-random-name>"` makes the serverless Alert Service also push every CRITICAL/HIGH alert to that page (open the URL in a browser to watch alerts arrive live). Save and close Notepad.
- **Next:** 8.3.

### 8.3 (Optional) Download the Flink → Prometheus reporter jar

- **Run:**
  ```powershell
  New-Item -ItemType Directory -Force flink/lib | Out-Null
  Invoke-WebRequest -Uri https://repo1.maven.org/maven2/org/apache/flink/flink-metrics-prometheus/1.17.0/flink-metrics-prometheus-1.17.0.jar -OutFile flink/lib/flink-metrics-prometheus-1.17.0.jar
  (Get-Item flink/lib/flink-metrics-prometheus-1.17.0.jar).Length
  ```
- **What it does:** Terraform uploads it to GCS so the Dataproc VM (which has no internet access) can expose Flink metrics to Prometheus. Without it the Flink panels in Grafana stay empty (the job itself still runs; the init script first tries the copy shipped with Dataproc).
- **Expected output:** a size of roughly `100000` bytes.
- **Next:** 8.4.

### 8.4 Initialise and validate the foundation stack

- **Run:**
  ```powershell
  terraform -chdir=infra/terraform/01-foundation init -backend-config="bucket=$($env:PROJECT_ID)-s19-tfstate"
  terraform -chdir=infra/terraform/01-foundation validate
  ```
- **What it does:** downloads the Google/random/archive providers and connects the stack to the state bucket; `validate` checks the code.
- **Expected output:**
  ```
  Initializing the backend...
  Successfully configured the backend "gcs"! ...
  - Installing hashicorp/google v6.x.x...
  Terraform has been successfully initialized!
  Success! The configuration is valid.
  ```
- **Next:** 8.5.

### 8.5 Preview the plan (free)

- **Run:**
  ```powershell
  terraform -chdir=infra/terraform/01-foundation plan -out tfplan
  ```
- **What it does:** lists everything that would be created, without creating anything.
- **Expected output** (last line): `Plan: 75 to add, 0 to change, 0 to destroy.` — **76** if you downloaded the reporter jar in 8.3, **+1** if you set `billing_account_id`. Scroll up to see e.g. `google_container_cluster.s19[0] will be created`, `google_sql_database_instance.pg will be created`, `google_cloudfunctions2_function.alert will be created`.
- **Check:** no `Error:` lines. The count can differ by a few if you changed variables.
- **Next:** 8.6 — **this is the first step that spends credit. Decide now.**

### 8.6 💲 BILLABLE — apply the foundation

- **Run:**
  ```powershell
  terraform -chdir=infra/terraform/01-foundation apply tfplan
  ```
- **What it does:** creates the VPC, subnet, firewall rules, Private Service Access, static IPs, the GKE cluster and node pool, Cloud SQL PostgreSQL (private IP), Firestore + index, the GCS data bucket, the Pub/Sub topic, Artifact Registry, the **Alert Service Cloud Run function + Eventarc trigger**, 7 service accounts with their IAM bindings, Workload Identity Federation for GitHub. **15–25 minutes** (Cloud SQL and GKE are the slow ones).
- **Expected output:**
  ```
  google_project_service.apis["container.googleapis.com"]: Creation complete after 2m3s ...
  google_container_cluster.s19[0]: Still creating... [6m0s elapsed]
  google_sql_database_instance.pg: Still creating... [9m0s elapsed]
  google_cloudfunctions2_function.alert: Creation complete after 2m41s [id=projects/.../functions/alert-service]
  ...
  Apply complete! Resources: 75 added, 0 changed, 0 destroyed.

  Outputs:
  alert_function = "alert-service"
  artifact_registry = "us-central1-docker.pkg.dev/s19-disaster-471203/s19"
  cloudsql_password = <sensitive>
  cloudsql_private_ip = "10.x.x.x"
  data_bucket = "s19-disaster-471203-s19-data"
  github_ci_service_account = "s19-ci@s19-disaster-471203.iam.gserviceaccount.com"
  github_wif_provider = "projects/123456789012/locations/global/workloadIdentityPools/s19-github/providers/github-oidc"
  gke_cluster_name = "s19-gke"
  ingress_ip = "34.x.x.x"
  kafka_ilb_ip = "10.10.0.100"
  ...
  ```
- **If it fails** — Terraform is safe to re-run: `terraform -chdir=infra/terraform/01-foundation apply` (without `tfplan`) continues where it stopped.
  - `Error 403: ... API has not been used in project ... or it is disabled` → the API was enabled seconds ago; wait 2 minutes and re-run.
  - `Permission denied while using the Eventarc Service Agent` / `Validation failed for trigger` → IAM propagation delay on new projects; wait 3–5 minutes and re-run.
  - `Quota 'CPUS_ALL_REGIONS' exceeded` / `SSD_TOTAL_GB` → reduce `gke_max_nodes` to 2 in `terraform.tfvars`, or request a quota increase (IAM & Admin → Quotas).
  - `googleapi: Error 409: Database already exists` (Firestore) → `terraform -chdir=infra/terraform/01-foundation import google_firestore_database.default "projects/$($env:PROJECT_ID)/databases/(default)"` and re-run.
  - `Error waiting for Create Service Networking Connection` → re-run apply.
- **Next:** 8.7.

### 8.7 Verify the infrastructure (Console + CLI)

- **Console** (☰ menu, project selected):

  | Page | You should see |
  |---|---|
  | **VPC network → VPC networks** | `s19-vpc` with subnet `s19-subnet` (10.10.0.0/20) |
  | **Kubernetes Engine → Clusters** | `s19-gke`, zone us-central1-a, green ✔, 2 nodes |
  | **SQL** | `s19-pg`, PostgreSQL 15, *Private IP* only, status Runnable |
  | **Firestore → Databases** | `(default)`, Native mode, nam5 |
  | **Cloud Storage → Buckets** | `<id>-s19-data` and `<id>-s19-tfstate` |
  | **Pub/Sub → Topics** | `alert-requests` (and an Eventarc subscription) |
  | **Cloud Run** | service `alert-service` (Function), trigger *Pub/Sub* |
  | **Artifact Registry → Repositories** | `s19` (Docker, us-central1), empty for now |
  | **IAM & Admin → Service Accounts** | the seven `s19-*` accounts |

- **CLI:**
  ```powershell
  gcloud container clusters list --format "table(name,location,status,currentNodeCount)"
  gcloud sql instances list --format "table(name,databaseVersion,state,ipAddresses[0].type)"
  gcloud functions list --regions us-central1 --format "table(name,state,environment)"
  gcloud pubsub topics list --format "value(name)"
  ```
- **Expected output:**
  ```
  NAME     LOCATION       STATUS   CURRENT_NODE_COUNT
  s19-gke  us-central1-a  RUNNING  2
  NAME    DATABASE_VERSION  STATE     TYPE
  s19-pg  POSTGRES_15       RUNNABLE  PRIVATE
  NAME           STATE   ENVIRONMENT
  alert-service  ACTIVE  GEN_2
  projects/s19-disaster-471203/topics/alert-requests
  ```
- **Next:** Part 9.

---

## Part 9 — Build and push the Docker images

### 9.1 Write your project id and repo URL into the GitOps manifests

- **Run** (your repo URL):
  ```powershell
  .\scripts\configure.ps1 -ProjectId $env:PROJECT_ID -RepoUrl https://github.com/<your-user>/s19-disaster-management.git
  git diff --stat
  ```
- **What it does:** replaces `REPLACE_GIT_REPO_URL` in `deploy/argocd/apps/*.yaml` and `REPLACE_PROJECT_ID` in `deploy/k8s/overlays/gcp/kustomization.yaml`.
- **Expected output:**
  ```
  updated C:\dev\s19-disaster-management\deploy\argocd\apps\10-kafka.yaml
  updated ...\20-monitoring.yaml
  updated ...\30-monitoring-extras.yaml
  updated ...\40-s19-services.yaml
  updated ...\deploy\k8s\overlays\gcp\kustomization.yaml
   5 files changed, 12 insertions(+), 12 deletions(-)
  ```
- **Next:** 9.2.

### 9.2 💲 Build and push the 7 images (Artifact Registry storage: cents)

- **Run:**
  ```powershell
  .\scripts\build_push.ps1 -ProjectId $env:PROJECT_ID -Tag v1
  ```
- **What it does:** logs Docker in to Artifact Registry, builds `incident-store`, `quorum-coordinator`, `incident-intake`, `resource-registry`, `dispatch`, `volunteer-coordination`, `situation-analytics` for `linux/amd64`, pushes them, then sets `newTag: v1` in the GitOps overlay. 5–15 minutes (the shared dependency layer is built once and reused).
- **Expected output:**
  ```
  Adding credentials for: us-central1-docker.pkg.dev
  >>> building incident-store:v1
  ...
  v1: digest: sha256:... size: 2416
  ...
  deploy\k8s\overlays\gcp\kustomization.yaml:12:    newTag: v1
  ... (7 lines)
  Pushed tag v1. Commit + push deploy/k8s/overlays/gcp/kustomization.yaml so Argo CD rolls it out.
  ```
- **Check:**
  ```powershell
  gcloud artifacts docker images list "us-central1-docker.pkg.dev/$($env:PROJECT_ID)/s19" --include-tags --format "table(package.basename(),tags)"
  ```
  Seven rows, each with tag `v1`.
- **If it fails:** `denied: Permission "artifactregistry.repositories.uploadArtifacts" denied` → `gcloud auth login` again with the Owner account. `docker build` fails on the `pip install` layer → network hiccup, re-run.
- **Next:** 9.3.

### 9.3 Commit and push the configuration

- **Run:**
  ```powershell
  git add -A
  git commit -m "Configure GCP project and pin images v1"
  git push
  ```
- **Expected output:** `main -> main`. On GitHub the files under `deploy/` now contain your project id and repo URL.
- **Next:** 9.4.

### 9.4 Let GitHub Actions build images on every push (CI)

- **Get the values:**
  ```powershell
  terraform -chdir=infra/terraform/01-foundation output -raw github_wif_provider; ""
  terraform -chdir=infra/terraform/01-foundation output -raw github_ci_service_account; ""
  ```
- **Where:** GitHub → your repo → **Settings** → **Secrets and variables** → **Actions** → tab **Variables** → **New repository variable** (four times):

  | Name | Value |
  |---|---|
  | `GCP_PROJECT_ID` | your project id |
  | `GCP_REGION` | `us-central1` |
  | `GCP_WIF_PROVIDER` | the `projects/…/providers/github-oidc` value |
  | `GCP_CI_SA` | `s19-ci@<project>.iam.gserviceaccount.com` |

- Then **Settings** → **Actions** → **General** → **Workflow permissions** → select **Read and write permissions** → **Save** (CI commits the new image tag back to the repo).
- **Test:** **Actions** → **ci** → **Run workflow** → **Run workflow**.
- **Expected result:** after ~8 minutes both `test` and `build-push` are green, and a new commit `deploy: images <sha> [skip ci]` by `s19-ci` appears on `main`. From now on, every push that changes `services/` builds and deploys automatically through Git.
- **Important:** run `git pull` before your next local commit (CI added a commit).
- **If it fails:** `Unable to acquire impersonated credentials` / `Permission 'iam.serviceAccounts.getAccessToken' denied` → `github_repo` in `terraform.tfvars` must exactly match `<owner>/<repo>` (case-sensitive); fix and `terraform apply` again. `refusing to allow ... to create or update workflow` / push `403` → the Workflow permissions setting above.
- **Next:** Part 10.

---

## Part 10 — Configure GKE and deploy through GitOps (Argo CD)

Requirement (d): Kubernetes workloads are deployed **only** by Argo CD from Git. You never run `kubectl apply` for the services. Terraform installs Argo CD itself plus the cluster plumbing (namespaces, Workload Identity service account, config map, secrets).

### 10.1 Connect kubectl to the cluster

- **Run:**
  ```powershell
  gcloud container clusters get-credentials s19-gke --zone us-central1-a --project $env:PROJECT_ID
  kubectl get nodes
  ```
- **Expected output:**
  ```
  Fetching cluster endpoint and auth data.
  kubeconfig entry generated for s19-gke.
  NAME                                   STATUS   ROLES    AGE   VERSION
  gke-s19-gke-primary-1a2b3c4d-abcd      Ready    <none>   20m   v1.3x.x-gke.xxxx
  gke-s19-gke-primary-1a2b3c4d-efgh      Ready    <none>   20m   v1.3x.x-gke.xxxx
  ```
- **If it fails:** `gke-gcloud-auth-plugin ... not found` → step 1.5, then open a new tab.
- **Next:** 10.2.

### 10.2 Fill in the platform variables

- **Run:**
  ```powershell
  Copy-Item infra/terraform/02-platform/terraform.tfvars.example infra/terraform/02-platform/terraform.tfvars
  notepad infra/terraform/02-platform/terraform.tfvars
  ```
- **What to enter:**
  ```hcl
  project_id     = "s19-disaster-471203"
  tfstate_bucket = "s19-disaster-471203-s19-tfstate"
  git_repo_url   = "https://github.com/<your-user>/s19-disaster-management.git"
  git_revision   = "main"
  # git_token    = "github_pat_..."   # ONLY if the repository is private (10.3)
  ```
- **Next:** 10.3 (private repo) or 10.4.

### 10.3 (Only for a private repository) create a read-only token

- **Where:** GitHub → your avatar → **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**. **Repository access:** *Only select repositories* → your repo. **Permissions → Repository permissions → Contents:** *Read-only*. Expiration: after your demo. **Generate**, copy it into `git_token` in `terraform.tfvars` (this file is git-ignored).
- **Next:** 10.4.

### 10.4 💲 Apply the platform stack (Argo CD)

- **Run:**
  ```powershell
  terraform -chdir=infra/terraform/02-platform init -backend-config="bucket=$($env:PROJECT_ID)-s19-tfstate"
  terraform -chdir=infra/terraform/02-platform apply
  ```
  Type `yes`.
- **What it does:** creates namespaces `s19`, `kafka`, `monitoring`; the Workload-Identity service account `s19-app`; ConfigMap `s19-cloud-config` (bucket, DB IP, Kafka address…); Secrets `s19-secrets` (DB password, admin token) and `grafana-admin`; installs **Argo CD** (Helm chart 9.5.15) and the **root application** (app-of-apps) that points at `deploy/argocd/apps` in your repo. 5–10 minutes.
- **Expected output:**
  ```
  Plan: 11 to add, 0 to change, 0 to destroy.
  ...
  helm_release.argocd: Creation complete after 2m10s [id=argocd]
  helm_release.argocd_root: Creation complete after 5s [id=s19-root]
  Apply complete! Resources: 11 added, 0 changed, 0 destroyed.
  Outputs:
  admin_token = <sensitive>
  argocd_initial_password_cmd = "kubectl -n argocd get secret argocd-initial-admin-secret ..."
  grafana_admin_password = <sensitive>
  ```
  (12 with a `git_token`.)
- **If it fails:** `Kubernetes cluster unreachable` → run 10.1 again. `context deadline exceeded` on `helm_release.argocd` → nodes were busy pulling images; re-run apply.
- **Next:** 10.5.

### 10.5 Watch Argo CD deploy everything from Git

- **Run** (repeat every minute; Ctrl+C stops `-w`):
  ```powershell
  kubectl -n argocd get applications -w
  ```
- **What happens:** the root app creates four child apps in waves: `kafka` and `monitoring` (wave 0) → `monitoring-extras` (wave 1) → `s19-services` (wave 2). Kafka's PostSync hook creates the 4 topics.
- **Expected output after 5–12 minutes:**
  ```
  NAME                SYNC STATUS   HEALTH STATUS
  kafka               Synced        Healthy
  monitoring          Synced        Healthy
  monitoring-extras   Synced        Healthy
  s19-root            Synced        Healthy
  s19-services        Synced        Healthy
  ```
- **If it fails:**
  - `s19-root  Unknown / ComparisonError ... repository not found` → the repo is private (10.3) or `git_repo_url` is wrong.
  - `s19-services Degraded` → `kubectl -n s19 get pods` and see 10.7.
  - `monitoring  OutOfSync` for a long time → normal on first sync (large CRDs); it retries automatically.
- **Next:** 10.6.

### 10.6 Open the Argo CD UI

- **Run** (keep this tab open; use a second tab for other commands):
  ```powershell
  $p = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
  "Argo CD password: " + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
  kubectl -n argocd port-forward svc/argocd-server 9080:80
  ```
- **Where:** browser → <http://localhost:9080> → user `admin`, the password printed above.
- **Expected result:** five application tiles, all **Healthy / Synced**. Click `s19-services` to see the tree: Deployments, StatefulSet `incident-store`, Services, HPAs, Ingress.
- **Next:** 10.7.

### 10.7 Check the pods

- **Run:**
  ```powershell
  kubectl -n s19 get pods -o wide
  kubectl -n kafka get pods
  kubectl -n monitoring get pods
  ```
- **Expected output:**
  ```
  NAME                                      READY   STATUS    RESTARTS   AGE
  dispatch-6d9c7b8f5d-x2k8p                 1/1     Running   0          6m
  incident-intake-7c5b9d6f4-9qwer           1/1     Running   0          6m
  incident-store-0                          1/1     Running   0          6m
  incident-store-1                          1/1     Running   0          6m
  incident-store-2                          1/1     Running   0          6m
  quorum-coordinator-5f7d8c9b6-abcde        1/1     Running   0          6m
  resource-registry-84f6c7d9b5-fghij        1/1     Running   0          6m
  situation-analytics-6b8d9f7c5-klmno       1/1     Running   0          6m
  volunteer-coordination-5c9d8b7f6-pqrst    1/1     Running   0          6m
  NAME      READY   STATUS    RESTARTS   AGE
  kafka-0   1/1     Running   0          9m
  ```
  and in `monitoring`: `kps-grafana-…`, `prometheus-kps-kube-prometheus-stack-prometheus-0`, `kps-kube-state-metrics-…`, `kps-prometheus-node-exporter-…` (one per node), `kps-kube-prometheus-stack-operator-…`, all Running.
- **If it fails:**
  - `ImagePullBackOff` → the tag in `deploy/k8s/overlays/gcp/kustomization.yaml` does not exist in Artifact Registry (9.2/9.3), or the project id was not configured (9.1).
  - `CreateContainerConfigError` → a Secret/ConfigMap is missing: 02-platform not applied (10.4).
  - `CrashLoopBackOff` on `resource-registry`/`dispatch` → `kubectl -n s19 logs deploy/resource-registry`; `connection timeout` means Cloud SQL is stopped (`cloudsql_running=false`).
  - `Pending` → not enough CPU; the cluster autoscaler adds the 3rd node within ~2 minutes.
- **Next:** 10.8.

### 10.8 The public URL

- **Run:**
  ```powershell
  kubectl -n s19 get ingress s19-public
  . .\scripts\env.ps1
  s19 GET /api/quorum/config
  ```
- **What it does:** the Ingress is a Google Cloud global external Application Load Balancer on the static IP from Terraform. `env.ps1` (without `-Local`) reads that IP and the admin token from Terraform outputs.
- **Expected output:**
  ```
  NAME         CLASS    HOSTS   ADDRESS       PORTS   AGE
  s19-public   <none>   *       34.x.x.x      80      8m
  S19 API base : http://34.x.x.x
  Admin token  : set
  HTTP 200  GET /api/quorum/config
  { "n": 3, "w": 2, "r": 2, "rPlusWGreaterThanN": true, ... }
  ```
- **If it fails:** `HTTP 502` or `404 (default backend)` for the first **5–10 minutes** is normal: the load balancer is being programmed and the health checks (`/healthz`) must pass. Check progress in Console → **Network services → Load balancing** (backends turn green). Still failing after 15 minutes → `kubectl -n s19 describe ingress s19-public` (events at the bottom).
- **Next:** Part 11.

---

## Part 11 — Verify all microservices and integrations

Everything in Parts 11–15 uses the public URL. Load the helper first in every new PowerShell tab:
```powershell
. .\scripts\env.ps1          # GCP (reads ingress_ip + admin_token from Terraform)
.\.venv\Scripts\Activate.ps1 # Python environment from 4.2
```

### 11.1 Seed demo data

- **Run:**
  ```powershell
  s19 POST "/api/volunteers/_seed?perRegion=8"
  s19 GET /api/resources/stats
  ```
- **What it does:** writes 40 volunteers (8 per region) to **Firestore**. Resources (5 regions × 7 kinds × 3 = 105 vehicles, supply kits and teams) were inserted into **Cloud SQL** by the Resource Registry's migration on first start.
- **Expected output:**
  ```
  HTTP 201  POST /api/volunteers/_seed?perRegion=8
  { "seeded": 40 }
  HTTP 200  GET /api/resources/stats
  { "byRegion": { "central": { "SUPPLY": { "AVAILABLE": 6 }, "TEAM": { "AVAILABLE": 6 }, "VEHICLE": { "AVAILABLE": 9 } }, "east": {...}, ... },
    "activeReservations": 0, "rows": [...] }
  ```
- **Next:** 11.2.

### 11.2 Run the end-to-end check against GCP

- **Run:**
  ```powershell
  python scripts/e2e_check.py | Tee-Object docs/evidence/e2e-check-gke.txt
  ```
- **What it does:** the same 29 checks as 5.4, now against GKE, Cloud SQL, Firestore, GCS, Pub/Sub, the Cloud Run function and Kafka on GKE. The output is saved as evidence.
- **Expected output:** `29/29 checks passed` (the alert checks wait up to 60 s because the function may cold-start).
- **If it fails:**
  - alert checks (`6.`, `8c.`) → Console → **Cloud Run** → `alert-service` → **Logs**; `PermissionDenied` there means IAM is still propagating, rerun in 2 minutes.
  - `4.` attachment → `kubectl -n s19 logs deploy/incident-intake --tail 30`; a `403` means Workload Identity is not ready: `kubectl -n s19 get sa s19-app -o yaml` must show the annotation `iam.gke.io/gcp-service-account`.
  - `8b.` auto-dispatch → `s19 GET /api/dispatch/_meta/consumer` (`lastError`), and `kubectl -n kafka get pods`.
- **Next:** 11.3.

### 11.3 Look at each integration yourself

| What | Command / page | Expected |
|---|---|---|
| **REST** (public) | `s19 POST /api/incidents @{reporterId='u1'; type='FLOOD'; severity='HIGH'; region='north'; description='river overflow at bridge'; latitude=28.6; longitude=77.2; peopleAffected=40}` | `HTTP 201`, `"quorum": {"acks": 2 or 3, "w": 2, "n": 3}`, `"kafkaEventQueued": true` — copy the `incidentId` |
| **gRPC** (coordinator → replicas) | `s19 GET /api/quorum/debug/<incidentId>` | one entry per replica, each with the same `versions[0].clock` — the coordinator fetched them with the `Get` RPC |
| **Kafka** | `kubectl -n kafka exec kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic incident-events --from-beginning --max-messages 3` | three JSON events `{"eventType":"INCIDENT_REPORTED",...}` then `Processed a total of 3 messages` |
| **Pub/Sub** | Console → **Pub/Sub** → `alert-requests` → **METRICS** | *Published messages* > 0 after a CRITICAL incident or a dispatch |
| **Cloud Storage** | `gcloud storage ls -r "gs://$($env:PROJECT_ID)-s19-data/raw/incidents/" \| Select-Object -First 5` (raw reports are flushed every 30 s) and `.../attachments/` | `.ndjson` batch objects and uploaded files |
| **Cloud SQL** | `s19 GET "/api/resources?region=north&status=RESERVED"` and `s19 GET "/api/dispatch?limit=5"` | rows from tables `resources` / `dispatch_assignments` |
| **Firestore** | Console → **Firestore** → **(default)** → **Data** | collections `volunteers`, `volunteer_assignments`, `alerts`, `notifications`, `broadcasts`, `analytics_windows` |

- **Upload an attachment (GCS):**
  ```powershell
  "photo placeholder" | Set-Content $env:TEMP\flood.txt
  Invoke-RestMethod -Method Post -Uri "$env:BASE_URL/api/incidents/<incidentId>/attachments" -Form @{ file = Get-Item $env:TEMP\flood.txt }
  ```
  Expected: `uri: gs://<id>-s19-data/attachments/<incidentId>/...-flood.txt`.
- **Next:** Part 12.

---

## Part 12 — Replication, quorum, failure handling and recovery

Requirement (f): leaderless replication (Dynamo-style). N = 3 replicas, W = 2, R = 2 (R + W > N). Background: [docs/DESIGN.md §4](docs/DESIGN.md).

### 12.1 Run the full consistency suite and save it

- **Run:**
  ```powershell
  python scripts/consistency_test.py | Tee-Object docs/evidence/consistency-test-gke.txt
  ```
- **Expected output:** `14/14 checks passed` (the same 14 checks passed when this project was tested; see [docs/evidence/sandbox/consistency-test.txt](docs/evidence/sandbox/consistency-test.txt)).
- **Next:** 12.2 shows the same behaviour step by step (for the live demo).

### 12.2 Step by step: a replica goes down, writes continue, recovery repairs it

- **Run:**
  ```powershell
  s19 POST /api/quorum/replicas/incident-store-2/fault @{mode='down'} -Admin
  $r = s19 POST /api/incidents @{reporterId='demo'; type='FLOOD'; severity='HIGH'; region='north'; description='written with replica 2 down'; latitude=28.6; longitude=77.2} -Raw
  $id = $r.incidentId; $r.quorum | ConvertTo-Json
  s19 GET /api/quorum/debug/$id
  s19 POST /api/quorum/replicas/incident-store-2/fault @{mode='none'} -Admin
  s19 POST /api/quorum/anti-entropy -Admin
  s19 GET /api/quorum/debug/$id
  ```
- **Expected output:**
  - the write returns `"acks": 2` and `"incident-store-2": "error: UNAVAILABLE: incident-store-2 is down (fault injection)"`;
  - `debug` shows `incident-store-2` → `"error": "UNAVAILABLE: ..."` while the other two hold the version;
  - anti-entropy returns `"repaired": { "incident-store-2": 1 }` (or more);
  - the final `debug` shows the same version on all three replicas.
- **Next:** 12.3.

### 12.3 Read repair after silent data loss

- **Run:**
  ```powershell
  s19 POST /api/quorum/replicas/incident-store-0/fault @{mode='drop_writes'} -Admin
  s19 PATCH /api/incidents/$id @{status='VERIFIED'; note='verified on site'; author='field-officer'}
  s19 POST /api/quorum/replicas/incident-store-0/fault @{mode='none'} -Admin
  s19 GET /api/quorum/debug/$id          # replica 0 still REPORTED (it dropped the write)
  s19 GET "/api/quorum/kv/$($id)?r=3"     # quorum read of all 3
  Start-Sleep 2; s19 GET /api/quorum/debug/$id
  ```
- **Expected output:** the `r=3` read returns `"status": "VERIFIED"` and `"staleReplicasInQuorum": ["incident-store-0"]`; two seconds later `debug` shows replica 0 at `VERIFIED` too (read repair).
- **Next:** 12.4.

### 12.4 Concurrent writes, siblings and semantic merge

- **Run:**
  ```powershell
  $cur = s19 GET "/api/quorum/kv/$id" -Raw
  $a = $cur.value.PSObject.Copy(); $a.status = 'DISPATCHED'
  $b = $cur.value.PSObject.Copy(); $b.severity = 'CRITICAL'
  s19 PUT "/api/quorum/kv/$id" @{value=$a; context=$cur.context; clientId='dispatch'}
  s19 PUT "/api/quorum/kv/$id" @{value=$b; context=$cur.context; clientId='field-officer'}
  s19 GET "/api/quorum/kv/$id"
  ```
- **What it does:** two writers update the incident from the **same** vector-clock context, so neither write has seen the other: a conflict.
- **Expected output:** `"conflict": true`, two `"siblings"` with concurrent clocks (e.g. `{"intake":1,"field-officer":1,"dispatch":1}` and `{"intake":1,"field-officer":2}`), `"resolvedBy": "semantic-merge"`, and the merged `value` keeps **both** changes: `"status": "DISPATCHED"`, `"severity": "CRITICAL"`. A second `GET` shows `"conflict": false` (the merge was written back).
- **Next:** 12.5.

### 12.5 Quorum loss and tunable consistency

- **Run:**
  ```powershell
  s19 POST /api/quorum/replicas/incident-store-1/fault @{mode='down'} -Admin
  s19 POST /api/quorum/replicas/incident-store-2/fault @{mode='down'} -Admin
  $cur = s19 GET "/api/quorum/kv/$($id)?r=1" -Raw
  s19 PUT "/api/quorum/kv/$id" @{value=$cur.value; context=$cur.context; clientId='dispatch'}          # W=2
  s19 PUT "/api/quorum/kv/$($id)?w=1" @{value=$cur.value; context=$cur.context; clientId='dispatch'}   # W=1
  s19 GET "/api/quorum/kv/$id"                                                                          # R=2
  s19 POST /api/quorum/replicas/incident-store-1/fault @{mode='none'} -Admin
  s19 POST /api/quorum/replicas/incident-store-2/fault @{mode='none'} -Admin
  s19 POST /api/quorum/anti-entropy -Admin
  ```
- **Expected output:** W=2 write → `HTTP 503 "write quorum not reached (1/2)"` (consistency over availability); W=1 → `HTTP 200 "acks": 1` (availability over consistency); R=2 read → `HTTP 503 "read quorum not reached (1/2)"`; after healing, anti-entropy repairs replicas 1 and 2.
- **Next:** 12.6.

### 12.6 A real pod crash (not injected)

- **Run** in two tabs:
  ```powershell
  # Tab A: keep writing (smoke test loops 5 times through every API)
  k6 run -e BASE_URL=$env:BASE_URL loadtest/k6/smoke.js
  # Tab B: kill a replica while Tab A runs
  kubectl -n s19 delete pod incident-store-1
  kubectl -n s19 get pods -l app=incident-store -w
  ```
- **Expected output:** Tab A finishes with `✓ checks.........: 100.00%` (writes kept succeeding with 2 of 3 replicas). Tab B shows `incident-store-1  0/1  Terminating` → `ContainerCreating` → `1/1 Running` (same name, same PersistentVolume, so it keeps its old data). Within 30 s the coordinator's background anti-entropy copies whatever it missed: `kubectl -n s19 logs deploy/quorum-coordinator --tail 20 | Select-String anti-entropy` shows `"anti-entropy repaired keys"`.
- **Also show:** `kubectl -n s19 get pdb incident-store` → `MIN AVAILABLE 2` (voluntary disruptions such as node upgrades can never take 2 replicas down at once).
- **Next:** Part 13.

---

## Part 13 — Serverless function, event triggers and Flink

### 13.1 Serverless Alert Service (Pub/Sub → Eventarc → Cloud Run function)

- **Run:**
  ```powershell
  $c = s19 POST /api/incidents @{reporterId='u2'; type='CYCLONE'; severity='CRITICAL'; region='east'; description='cyclone landfall, coastal flooding'; latitude=22.5; longitude=88.3; peopleAffected=1200} -Raw
  $c | ConvertTo-Json -Depth 5
  Start-Sleep 20
  s19 GET "/api/analytics/alerts?limit=3"
  s19 GET /api/volunteers/broadcasts/east
  gcloud functions logs read alert-service --region us-central1 --limit 15
  ```
- **What it does:** Intake publishes a `CRITICAL_INCIDENT` message to Pub/Sub; Eventarc invokes the function; it writes each available volunteer's inbox (`notifications/{volunteer}/inbox`), a regional broadcast (`broadcasts/east/messages`), optionally POSTs to your webhook, and records the delivery report in `alerts/{messageId}`. In parallel, Dispatch consumes the Kafka event and **auto-dispatches** resources.
- **Expected output:** `"alertPublished": true`; an alert with `"alertType": "CRITICAL_INCIDENT"`, `"channels": ["inbox","broadcast"]` (plus `"webhook"` if configured), `"delivered": <n>`, `"failed": 0`; the broadcast list contains the incident; the function log shows `notification delivered` and `alert processed` lines.
- **Console:** **Cloud Run** → `alert-service` → **METRICS** (request count) and **LOGS**; **Eventarc** → **Triggers** → the Pub/Sub trigger.
- **Next:** 13.2.

### 13.2 Event-driven processing with Kafka

- **Run:**
  ```powershell
  s19 GET "/api/dispatch?status=ACTIVE&limit=5"
  kubectl -n kafka exec kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic dispatch-events --from-beginning --max-messages 2
  kubectl -n kafka exec kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic consistency-events --from-beginning --max-messages 3
  ```
- **Expected output:** an ACTIVE dispatch with `"mode": "AUTO"` for the CRITICAL incident (created by the Kafka consumer, not by a REST call); `DISPATCH_CREATED` events; `READ_REPAIR` / `CONFLICT_DETECTED` / `QUORUM_FAILURE` events from Part 12.
- **Next:** 13.3.

### 13.3 💲 BILLABLE — Create the Flink cluster on Dataproc (~$0.09/hour)

- **Run:**
  ```powershell
  notepad infra/terraform/01-foundation/terraform.tfvars    # set: dataproc_enabled = true
  terraform -chdir=infra/terraform/01-foundation apply
  terraform -chdir=infra/terraform/02-platform apply
  ```
- **What it does:** creates the single-node Dataproc cluster `s19-flink` (image 2.2 → Flink 1.17 on YARN, internal IP only, Cloud Logging enabled, auto-deleted after 2 hours **without a running job**). The second apply registers the Dataproc VM as a Prometheus target (`monitoring/flink-metrics`).
- **Expected output:** first apply `Plan: 1 to add, ...` → `google_dataproc_cluster.flink[0]: Creation complete after 3m...`; second apply `Plan: 2 to add` (Service + Endpoints).
- **If it fails:** `Insufficient 'CPUS' quota` → the free trial allows 8 vCPUs at once: 3 GKE nodes × 2 + 2 = 8; scale GKE to 2 nodes first or wait for the autoscaler to scale in.
- **Next:** 13.4.

### 13.4 💲 Submit the Flink job

- **Run:**
  ```powershell
  .\scripts\submit_flink_job.ps1 -ProjectId $env:PROJECT_ID
  gcloud dataproc jobs list --region us-central1 --cluster s19-flink --format "table(reference.jobId,status.state,placement.clusterName)"
  ```
- **What it does:** builds the jar in Docker (4.3), uploads it to `gs://<id>-s19-data/dataproc/jobs/`, and runs it on Dataproc reading Kafka through the internal load balancer `10.10.0.100:9094`.
- **Expected output:**
  ```
  Job [5c2f...] submitted.
  Submitted. Check: gcloud dataproc jobs list --region us-central1 --cluster s19-flink
  JOB_ID      STATE    CLUSTER_NAME
  5c2f...     RUNNING  s19-flink
  ```
- **Flink UI:** Console → **Dataproc** → **Clusters** → `s19-flink` → **WEB INTERFACES** → **YARN ResourceManager** → the running application → **ApplicationMaster** link → Flink dashboard → job `s19-situation-analytics`: graph *kafka-disaster-events → parse-json-envelope → event-time-watermarks → tumbling-window-per-region → surge-detector-keyed-state → to-json → kafka-incident-aggregates*. **Checkpoints** tab shows completed checkpoints every 30 s.
- **If it fails:** state `ERROR` → `gcloud dataproc jobs describe <JOB_ID> --region us-central1` and the driver output link. `TimeoutException ... 10.10.0.100:9094` → `kubectl -n kafka get svc kafka-external` must show `EXTERNAL-IP 10.10.0.100`.
- **Next:** 13.5.

### 13.5 Verify the Flink results

- **Run:**
  ```powershell
  k6 run -e BASE_URL=$env:BASE_URL -e PEAK_VUS=10 -e HOLD=2m loadtest/k6/hpa-load.js   # traffic for ~5 minutes
  kubectl -n kafka exec kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic incident-aggregates --from-beginning --max-messages 3
  s19 GET "/api/analytics/windows?region=north&limit=3"
  s19 GET /api/analytics/summary
  ```
- **Expected output:** JSON window results such as
  ```json
  {"region":"north","windowStart":1763460000000,"windowEnd":1763460060000,"incidents":84,"critical":2,"updates":0,
   "uniqueReporters":61,"dispatches":2,"resourcesDispatched":6,"volunteersDispatched":10,"resolved":0,"conflicts":0,
   "readRepairs":0,"quorumFailures":0,"antiEntropyRepairs":0,"prevIncidents":79,"baseline":80.5,"surge":false,"emittedAt":...}
  ```
  one per region per minute (stateful 1-minute tumbling windows, distinct reporters, cross-window surge detection) on the separate `incident-aggregates` topic, persisted in Firestore `analytics_windows`, and served by `/api/analytics/windows`. `summary.surgingRegions` lists regions where Flink flagged a surge.
- **Next:** Part 14. **After the demo set `dataproc_enabled = false` and apply again** (Part 17).

---

## Part 14 — Monitoring, logging and dashboards

### 14.1 Grafana dashboard

- **Run** (keep the tab open):
  ```powershell
  "Grafana password: " + (terraform -chdir=infra/terraform/02-platform output -raw grafana_admin_password)
  kubectl -n monitoring port-forward svc/kps-grafana 3000:80
  ```
- **Where:** browser → <http://localhost:3000> → user `admin` + the password → **Dashboards** → **S19 Disaster Management - Overview**.
- **Expected result:** four rows of panels: **golden signals** (total RPS, 5xx error %, p95 latency, RPS / error rate / p50-p95-p99 latency per service), **Kubernetes health & HPA** (nodes ready, pods not ready, HPA current vs desired replicas, CPU/memory per pod, restarts), **Dynamo** (quorum ops by result, read repairs, anti-entropy repairs, conflicts, replica up/fault mode, keys per replica), **Flink & analytics** (job uptime, checkpoints, records in/out, parsed events, surges, window lag). Run some traffic (13.5) to fill the graphs.
- **If it fails:** `svc "kps-grafana" not found` → `kubectl -n monitoring get svc` and use the Grafana service name shown. Empty service panels → 14.2.
- **Next:** 14.2.

### 14.2 Prometheus targets

- **Run:** `kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090`, open <http://localhost:9090> → **Status** → **Targets**.
- **Expected result:** `serviceMonitor/s19/s19-services/0` with 8 **UP** endpoints (the 7 HTTP services; replicas are scraped on their `metrics` port by endpoint `/1`), the kube-state-metrics / node-exporter / kubelet targets UP, and job `flink` UP while the Dataproc cluster runs.
- **Next:** 14.3.

### 14.3 Centralised logging (Cloud Logging)

- **Where:** Console → ☰ → **Logging** → **Logs Explorer**. Paste each query into the query box → **Run query**.

  | Purpose | Query |
  |---|---|
  | All S19 microservices | `resource.type="k8s_container" AND resource.labels.namespace_name="s19"` |
  | One service (JSON field) | `jsonPayload.service="quorum-coordinator"` |
  | Read repairs and anti-entropy | `jsonPayload.message=~"read repair\|anti-entropy"` |
  | Serverless Alert Service | `resource.type="cloud_run_revision" AND resource.labels.service_name="alert-service"` |
  | Flink job on Dataproc (driver + YARN containers) | `resource.type="cloud_dataproc_cluster" AND resource.labels.cluster_name="s19-flink"` |
  | Dataproc job driver | `resource.type="cloud_dataproc_job"` |
  | Errors from everything | `severity>=ERROR` |

- **Expected result:** structured entries (each service logs one JSON object per line, so fields like `incidentId`, `replica`, `region` are searchable), from GKE, from the function and from the Flink job.
- **Next:** Part 15.

---

## Part 15 — Load test and autoscaling (HPA)

Requirement (c): HPAs on `incident-intake` (CPU) and `quorum-coordinator` (CPU + memory), sustained k6 traffic shows scale-out.

### 15.1 Before you start

- On demo day prefer on-demand nodes: set `use_spot_nodes = false` in `01-foundation/terraform.tfvars` and `terraform -chdir=infra/terraform/01-foundation apply` (nodes are replaced; Argo CD reschedules everything).
- Check the HPAs see metrics:
  ```powershell
  kubectl -n s19 get hpa
  ```
  Expected:
  ```
  NAME                 REFERENCE                       TARGETS                         MINPODS   MAXPODS   REPLICAS
  incident-intake      Deployment/incident-intake      cpu: 3%/50%                     1         5         1
  quorum-coordinator   Deployment/quorum-coordinator   cpu: 4%/50%, memory: 40%/80%    1         5         1
  ```
  `<unknown>` for the first minute after deployment is normal.

### 15.2 💲 Run the load test and record the scaling

- **Run** in three tabs (each: `cd C:\dev\s19-disaster-management; . .\scripts\env.ps1`):
  ```powershell
  # Tab 1 - record HPA/pods/nodes every 15 s into docs/evidence/hpa-scaling.log
  .\scripts\record_hpa.ps1
  # Tab 2 - live view
  kubectl -n s19 get hpa -w
  # Tab 3 - 9 minutes of traffic: ramp to 40 virtual users, hold 6 minutes, ramp down
  New-Item -ItemType Directory -Force loadtest/results | Out-Null
  k6 run -e BASE_URL=$env:BASE_URL --summary-export loadtest/results/summary.json loadtest/k6/hpa-load.js | Tee-Object docs/evidence/k6-hpa-run.txt
  ```
- **What it does:** 70 % incident reports (quorum writes W=2) and 30 % reads (R=2) through the load balancer, ~2 % CRITICAL.
- **Expected output:**
  - Tab 2 within 1–3 minutes:
    ```
    incident-intake      Deployment/incident-intake      cpu: 182%/50%   1   5   1
    incident-intake      Deployment/incident-intake      cpu: 182%/50%   1   5   3
    quorum-coordinator   Deployment/quorum-coordinator   cpu: 140%/50%, memory: 45%/80%   1   5   3
    incident-intake      Deployment/incident-intake      cpu: 71%/50%    1   5   5
    ```
  - Tab 3 at the end:
    ```
    ✓ write 201
    ✓ read 200
    checks.........................: 99.xx% ✓ ...  ✗ ...
    http_req_duration..............: avg=...ms  p(95)=...ms
    http_req_failed................: 0.xx%
    incident_writes................: ...
    ```
    and thresholds `http_req_failed rate<0.05` ✓.
  - About 90 s after the load stops, replicas go back down to 1 (scale-in stabilisation window).
- **If it fails:** HPA stays at 1 replica with low CPU → raise the load: `-e PEAK_VUS=80`. Many `✗ write 201` with `503` → the cluster is out of CPU: `kubectl get nodes` (the autoscaler adds node 3); pods `Pending` resolve within ~2 minutes.
- **Next:** stop Tab 1 with **Ctrl+C**; take the screenshots of Part 16.

---

## Part 16 — Collect submission evidence

Save files in `docs/evidence/` (commit them) and screenshots in a folder you upload.

| # | Evidence | How | Requirement |
|---|---|---|---|
| 1 | `terraform state list` | `terraform -chdir=infra/terraform/01-foundation state list > docs/evidence/terraform-state-01.txt` | a |
| 2 | Terraform "no changes" plan | `terraform -chdir=infra/terraform/01-foundation plan` → screenshot `No changes.` | a |
| 3 | Cloud Run function + Eventarc trigger | Console screenshots; `gcloud functions logs read alert-service --region us-central1 --limit 30 > docs/evidence/alert-function-logs.txt` | b |
| 4 | REST/gRPC/Kafka/Pub/Sub working | `docs/evidence/e2e-check-gke.txt` (11.2) + Kafka consumer output (11.3) | b |
| 5 | GKE workloads | `kubectl get pods -A -o wide > docs/evidence/pods.txt`; GKE Workloads page screenshot | c |
| 6 | HPA scale-out under load | `docs/evidence/hpa-scaling.log`, `docs/evidence/k6-hpa-run.txt`, Grafana HPA panel screenshot | c |
| 7 | GitOps | Argo CD UI screenshot (all Synced/Healthy); a change pushed to Git and synced (demo guide step D3) | d |
| 8 | Flink on Dataproc | `gcloud dataproc jobs list ... > docs/evidence/dataproc-jobs.txt`; Flink job graph + checkpoints screenshots; `incident-aggregates` consumer output | e |
| 9 | Leaderless replication | `docs/evidence/consistency-test-gke.txt` (12.1); 12.2–12.6 outputs | f |
| 10 | Three storage products | Console screenshots: GCS objects, Cloud SQL instance, Firestore collections | g |
| 11 | Observability | Grafana dashboard screenshot; Logs Explorer screenshots (services, function, Dataproc) | h |
| 12 | Public URL | browser screenshot of `http://<INGRESS_IP>/api/quorum/config` | — |

Then:
```powershell
git add docs/evidence task_divison.txt
git commit -m "Add deployment evidence"
git pull --rebase
git push
```

**Never** include in screenshots or files: `terraform.tfvars` with a token, `cloudsql_password`, `admin_token`, the Grafana or Argo CD passwords.

---

## Part 17 — Clean up safely and avoid charges

Details and per-resource prices: [docs/COST_AND_CLEANUP.md](docs/COST_AND_CLEANUP.md).

### 17.1 Pause at the end of EVERY working session (keeps data and images)

- **Run:**
  ```powershell
  .\scripts\teardown_k8s.ps1 -ProjectId $env:PROJECT_ID
  terraform -chdir=infra/terraform/02-platform destroy -auto-approve
  terraform -chdir=infra/terraform/01-foundation apply -auto-approve -var gke_enabled=false -var cloudsql_running=false -var dataproc_enabled=false
  ```
- **What it does:** (1) deletes the Argo CD applications so Kubernetes releases the load balancer, the Kafka internal LB and the persistent disks *before* the cluster disappears (otherwise they can be orphaned and keep billing); (2) removes Argo CD; (3) deletes the GKE cluster, the Dataproc cluster and the static public IP, and stops Cloud SQL (data kept).
- **Expected output:**
  ```
  >> waiting for load balancers and volumes to be released
     ingresses=0 lb-services=0 pvcs=0
  >> leftover forwarding rules (should be empty):
  Listed 0 items.
  >> unattached persistent disks (should be empty):
  Listed 0 items.
  ...
  Destroy complete! Resources: 11 destroyed.          (13 if the Dataproc cluster existed)
  ...
  Apply complete! Resources: 0 added, 1 changed, 4 destroyed.   (5 with Dataproc)
  ```
- **Check:** Console → **Compute Engine → VM instances**: empty. **Kubernetes Engine**: no clusters. **SQL**: `s19-pg` *Stopped*.
- **Cost while paused:** a few cents per day (Cloud SQL disk, small buckets, images).

### 17.2 Resume the next session

- **Run:**
  ```powershell
  terraform -chdir=infra/terraform/01-foundation apply -auto-approve -var gke_enabled=true -var cloudsql_running=true
  gcloud container clusters get-credentials s19-gke --zone us-central1-a --project $env:PROJECT_ID
  terraform -chdir=infra/terraform/02-platform apply -auto-approve
  ```
  then 10.5–10.8 and 11.1 (seed volunteers again if you want; resources persist in Cloud SQL). Argo CD redeploys everything from Git automatically. **Note:** the `-var` values override `terraform.tfvars` only for that command; a plain `apply` later uses the values in the file again.

### 17.3 Final cleanup after grading (deletes everything)

- **Run:**
  ```powershell
  .\scripts\teardown_k8s.ps1 -ProjectId $env:PROJECT_ID
  terraform -chdir=infra/terraform/02-platform destroy -auto-approve
  terraform -chdir=infra/terraform/01-foundation destroy -auto-approve
  gcloud storage rm -r "gs://$($env:PROJECT_ID)-s19-tfstate"
  terraform -chdir=infra/terraform/00-bootstrap destroy -auto-approve -var "project_id=$env:PROJECT_ID"
  ```
  The last command may say the bucket is already gone; that is fine.
- **Then verify nothing is left:**
  ```powershell
  gcloud compute forwarding-rules list; gcloud compute addresses list; gcloud compute disks list
  gcloud dataproc clusters list --region us-central1; gcloud sql instances list; gcloud container clusters list
  ```
  Every command should print `Listed 0 items.`
- **Simplest absolute stop:** Console → ☰ → **IAM & Admin** → **Settings** → **SHUT DOWN** (project id) — stops all billing for the project; it is deleted after 30 days.

---

## Part 18 — Troubleshooting index

| Symptom | Where | Fix |
|---|---|---|
| `running scripts is disabled on this system` | PowerShell | 1.2 (`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`) and `Get-ChildItem -Recurse *.ps1 \| Unblock-File` |
| `s19 : The term 's19' is not recognized` | PowerShell | dot-source the helper: `. .\scripts\env.ps1` (note the leading dot and space) |
| `SkipHttpErrorCheck` parameter not found | PowerShell | you are in Windows PowerShell 5.1 — open **PowerShell 7** (1.1) |
| `/usr/bin/env: 'bash\r': No such file` or `$'\r': command not found` during `docker build` | Docker | files have CRLF endings: re-extract the ZIP / re-clone with `core.autocrlf false` |
| `docker: error during connect` | Docker | start Docker Desktop and wait |
| local `HTTP 502` from `localhost:8080` | local | the service behind that path is still starting: `docker compose ps`, `docker compose logs <service>` |
| `Error 403 ... API has not been used` | Terraform | wait 2 minutes, re-run `apply` |
| `Error acquiring the state lock` | Terraform | a previous run was interrupted: `terraform -chdir=<dir> force-unlock <LOCK_ID>` (id is in the message) |
| `oauth2: cannot fetch token` / `could not find default credentials` | Terraform | `gcloud auth application-default login` |
| `ImagePullBackOff` | GKE | 9.1–9.3: images pushed with the tag in the overlay, project id configured, changes pushed to GitHub |
| Argo CD app `Unknown`, `repository not found` | Argo CD | repo URL in `02-platform/terraform.tfvars`, or private repo without token (10.3) |
| `HTTP 502` from the Ingress IP | GKE | wait 10 minutes after first deploy; Console → Load balancing → backend health |
| `401 missing or wrong X-Admin-Token` | API | `. .\scripts\env.ps1` loads the token; or pass `-Admin` to `s19` |
| Alert checks fail on GCP | Cloud Run | function logs (13.1); Eventarc IAM propagation can take a few minutes on a new project |
| Flink job `ERROR` / no windows | Dataproc | 13.4; Kafka internal LB must be `10.10.0.100`; windows appear ~1–2 min after traffic |
| HPA `<unknown>` | GKE | wait 1–2 minutes for metrics-server; pods must have CPU requests (they do) |
| `Quota ... exceeded` | GCP | free trial = 8 vCPU at once: keep `gke_max_nodes = 3` and Dataproc only when needed |
