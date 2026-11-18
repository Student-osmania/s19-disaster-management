# ---------------------------------------------------------------- service accounts
resource "google_service_account" "gke_nodes" {
  account_id   = "s19-gke-nodes"
  display_name = "S19 GKE node pool (least privilege)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "workload" {
  account_id   = "s19-workload"
  display_name = "S19 microservices (Workload Identity for KSA s19/s19-app)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "alert_fn" {
  account_id   = "s19-alert-fn"
  display_name = "S19 Alert Service runtime (Cloud Run functions)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "eventarc" {
  account_id   = "s19-eventarc"
  display_name = "S19 Eventarc trigger identity"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "fn_build" {
  account_id   = "s19-fn-build"
  display_name = "S19 Cloud Build identity for function builds"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "dataproc" {
  account_id   = "s19-dataproc"
  display_name = "S19 Dataproc (Flink) VM identity"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "ci" {
  account_id   = "s19-ci"
  display_name = "S19 GitHub Actions image publisher"
  depends_on   = [google_project_service.apis]
}

# ---------------------------------------------------------------- project role bindings
locals {
  project_roles = {
    nodes_log      = ["gke_nodes", "roles/logging.logWriter"]
    nodes_metric   = ["gke_nodes", "roles/monitoring.metricWriter"]
    nodes_mviewer  = ["gke_nodes", "roles/monitoring.viewer"]
    nodes_meta     = ["gke_nodes", "roles/stackdriver.resourceMetadata.writer"]
    nodes_ar       = ["gke_nodes", "roles/artifactregistry.reader"]
    nodes_default  = ["gke_nodes", "roles/container.defaultNodeServiceAccount"]
    wl_firestore   = ["workload", "roles/datastore.user"]
    wl_pubsub      = ["workload", "roles/pubsub.publisher"]
    fn_firestore   = ["alert_fn", "roles/datastore.user"]
    fn_log         = ["alert_fn", "roles/logging.logWriter"]
    ea_receiver    = ["eventarc", "roles/eventarc.eventReceiver"]
    ea_invoker     = ["eventarc", "roles/run.invoker"]
    build_log      = ["fn_build", "roles/logging.logWriter"]
    build_ar       = ["fn_build", "roles/artifactregistry.writer"]
    build_storage  = ["fn_build", "roles/storage.objectViewer"]
    build_builder  = ["fn_build", "roles/cloudbuild.builds.builder"] # documented role for a custom build SA
    dataproc_wkr   = ["dataproc", "roles/dataproc.worker"]
    dataproc_log   = ["dataproc", "roles/logging.logWriter"]
    dataproc_metric = ["dataproc", "roles/monitoring.metricWriter"]
  }
  sa_emails = {
    gke_nodes = google_service_account.gke_nodes.email
    workload  = google_service_account.workload.email
    alert_fn  = google_service_account.alert_fn.email
    eventarc  = google_service_account.eventarc.email
    fn_build  = google_service_account.fn_build.email
    dataproc  = google_service_account.dataproc.email
  }
}

resource "google_project_iam_member" "roles" {
  for_each = local.project_roles
  project  = var.project_id
  role     = each.value[1]
  member   = "serviceAccount:${local.sa_emails[each.value[0]]}"
}

# Workload Identity: KSA s19/s19-app  ->  GSA s19-workload
resource "google_service_account_iam_member" "workload_identity" {
  count              = var.gke_enabled ? 1 : 0
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[s19/s19-app]"
  depends_on         = [google_container_cluster.s19]
}

# ---------------------------------------------------------------- GitHub Actions -> Artifact Registry (keyless)
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "s19-github"
  display_name              = "S19 GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }
  attribute_condition = "assertion.repository == '${var.github_repo}'"
  oidc { issuer_uri = "https://token.actions.githubusercontent.com" }
}

resource "google_service_account_iam_member" "ci_wif" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

resource "google_artifact_registry_repository_iam_member" "ci_writer" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.ci.email}"
}
