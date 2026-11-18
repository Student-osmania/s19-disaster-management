# Managed Flink: single-node Dataproc cluster (image 2.2 -> Flink 1.17.0 optional component).
# Created only when var.dataproc_enabled = true, and auto-deleted after var.dataproc_idle_ttl.
resource "google_storage_bucket_object" "flink_init" {
  name   = "dataproc/init/init-flink-prometheus.sh"
  bucket = google_storage_bucket.data.name
  source = "${path.module}/files/init-flink-prometheus.sh"
}

resource "google_storage_bucket_object" "flink_prom_jar" {
  count  = fileexists(var.flink_prometheus_jar) ? 1 : 0
  name   = "dataproc/lib/flink-metrics-prometheus-1.17.0.jar"
  bucket = google_storage_bucket.data.name
  source = var.flink_prometheus_jar
}

resource "google_dataproc_cluster" "flink" {
  count  = var.dataproc_enabled ? 1 : 0
  name   = "s19-flink"
  region = var.region

  cluster_config {
    staging_bucket = google_storage_bucket.data.name
    temp_bucket    = google_storage_bucket.data.name

    gce_cluster_config {
      zone                   = var.zone
      subnetwork             = google_compute_subnetwork.main.self_link
      internal_ip_only       = true
      service_account        = google_service_account.dataproc.email
      service_account_scopes = ["cloud-platform"]
      tags                   = ["s19-dataproc"]
    }

    master_config {
      num_instances = 1
      machine_type  = var.dataproc_machine_type
      disk_config {
        boot_disk_type    = "pd-standard"
        boot_disk_size_gb = 30
      }
    }
    # no worker_config + allow.zero.workers => single-node cluster (master runs YARN + Flink)

    software_config {
      image_version       = "2.2-debian12"
      optional_components = ["FLINK"]
      override_properties = {
        "dataproc:dataproc.allow.zero.workers"                    = "true"
        "dataproc:dataproc.logging.stackdriver.enable"            = "true"
        "dataproc:dataproc.logging.stackdriver.job.driver.enable" = "true"
        "dataproc:dataproc.logging.stackdriver.job.yarn.container.enable" = "true"
        "dataproc:jobs.file-backed-output.enable"                 = "true"
        # Flink -> Prometheus (scraped from GKE through Service monitoring/flink-metrics)
        "flink:metrics.reporter.prom.factory.class" = "org.apache.flink.metrics.prometheus.PrometheusReporterFactory"
        "flink:metrics.reporter.prom.port"          = "9250-9260"
      }
    }

    initialization_action {
      script      = "gs://${google_storage_bucket.data.name}/${google_storage_bucket_object.flink_init.name}"
      timeout_sec = 300
    }

    endpoint_config { enable_http_port_access = true } # Component Gateway -> Flink / YARN web UIs

    lifecycle_config { idle_delete_ttl = var.dataproc_idle_ttl }
  }

  depends_on = [google_project_iam_member.roles, google_storage_bucket_iam_member.dataproc_rw,
  google_storage_bucket_object.flink_prom_jar]
}

data "google_compute_instance" "flink_master" {
  count = var.dataproc_enabled ? 1 : 0
  name  = google_dataproc_cluster.flink[0].cluster_config[0].master_config[0].instance_names[0]
  zone  = var.zone
}
