# ---------------------------------------------------------------- Firestore (NoSQL)
# Volunteers (high-churn availability), alert delivery records, Flink window results.
# The Firestore free quota applies to the "(default)" database.
resource "google_firestore_database" "default" {
  name                    = "(default)"
  location_id             = var.firestore_location
  type                    = "FIRESTORE_NATIVE"
  concurrency_mode        = "OPTIMISTIC"
  delete_protection_state = "DELETE_PROTECTION_DISABLED"
  deletion_policy         = "DELETE"
  depends_on              = [google_project_service.apis]
}

# Situation Analytics: WHERE region == X ORDER BY windowStart DESC
resource "google_firestore_index" "windows_by_region" {
  database   = google_firestore_database.default.name
  collection = "analytics_windows"
  fields {
    field_path = "region"
    order      = "ASCENDING"
  }
  fields {
    field_path = "windowStart"
    order      = "DESCENDING"
  }
}

# ---------------------------------------------------------------- Cloud Storage (object store)
# raw/incidents/...    NDJSON batches of every raw report (audit / replay)
# attachments/<id>/... photos & documents uploaded with incidents
# functions/           Alert Service source archive
# dataproc/            init action + Flink Prometheus reporter jar, Flink job jar, Dataproc staging/temp
resource "google_storage_bucket" "data" {
  name                        = "${var.project_id}-s19-data"
  location                    = upper(var.region) # regional us-central1 => counts toward Always Free 5 GB
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  lifecycle_rule {
    condition {
      age            = 30
      matches_prefix = ["raw/"]
    }
    action { type = "Delete" }
  }
  lifecycle_rule {
    condition {
      age            = 7
      matches_prefix = ["dataproc/staging/", "dataproc/temp/"]
    }
    action { type = "Delete" }
  }
  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "workload_rw" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.workload.email}"
}

resource "google_storage_bucket_iam_member" "dataproc_rw" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataproc.email}"
}

# ---------------------------------------------------------------- Pub/Sub (message queue #2)
resource "google_pubsub_topic" "alerts" {
  name                       = "alert-requests"
  message_retention_duration = "86400s"
  depends_on                 = [google_project_service.apis]
}

# ---------------------------------------------------------------- Artifact Registry
resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "s19"
  format        = "DOCKER"
  description   = "S19 microservice images"
  # keep storage under the 0.5 GB free allotment
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions { keep_count = 3 }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition { older_than = "604800s" }
  }
  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------- optional budget alert
resource "google_billing_budget" "s19" {
  count           = var.billing_account_id == "" ? 0 : 1
  billing_account = var.billing_account_id
  display_name    = "s19-cc-assignment"
  budget_filter { projects = ["projects/${data.google_project.this.number}"] }
  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }
  threshold_rules { threshold_percent = 0.25 }
  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  depends_on = [google_project_service.apis] # billingbudgets.googleapis.com must be enabled first
}
