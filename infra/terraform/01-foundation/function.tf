# Alert Service = asynchronous, event-driven serverless function (requirement b).
# Cloud Run functions (2nd gen) triggered by Pub/Sub topic alert-requests via Eventarc.
data "archive_file" "alert_fn" {
  type        = "zip"
  source_dir  = "${path.module}/../../../services/alert-function"
  output_path = "${path.module}/.build/alert-function.zip"
  excludes    = ["__pycache__", "*.pyc"]
}

resource "google_storage_bucket_object" "alert_fn_src" {
  name   = "functions/alert-function-${data.archive_file.alert_fn.output_md5}.zip"
  bucket = google_storage_bucket.data.name
  source = data.archive_file.alert_fn.output_path
}

resource "google_cloudfunctions2_function" "alert" {
  name     = "alert-service"
  location = var.region

  build_config {
    runtime         = "python312"
    entry_point     = "handle_alert"
    service_account = google_service_account.fn_build.id
    source {
      storage_source {
        bucket = google_storage_bucket.data.name
        object = google_storage_bucket_object.alert_fn_src.name
      }
    }
  }

  service_config {
    min_instance_count    = 0 # scale to zero -> no idle cost
    max_instance_count    = 3
    available_memory      = "256M"
    timeout_seconds       = 60
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = google_service_account.alert_fn.email
    environment_variables = {
      GCP_PROJECT_ID     = var.project_id
      FIRESTORE_DATABASE = google_firestore_database.default.name
      MAX_RECIPIENTS     = "25"
      # optional real external channel (Slack/Discord incoming webhook or https://ntfy.sh/<topic>)
      ALERT_WEBHOOK_URL = var.alert_webhook_url
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.alerts.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.eventarc.email
  }

  depends_on = [google_project_iam_member.roles]
}
