output "project_id" { value = var.project_id }
output "region" { value = var.region }
output "zone" { value = var.zone }
output "gke_cluster_name" { value = var.gke_enabled ? google_container_cluster.s19[0].name : "" }
output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
output "data_bucket" { value = google_storage_bucket.data.name }
output "alert_topic" { value = google_pubsub_topic.alerts.name }
output "cloudsql_private_ip" { value = google_sql_database_instance.pg.private_ip_address }
output "cloudsql_db_name" { value = google_sql_database.s19.name }
output "cloudsql_user" { value = google_sql_user.app.name }
output "cloudsql_password" {
  value     = random_password.db.result
  sensitive = true
}
output "firestore_database" { value = google_firestore_database.default.name }
output "workload_gsa_email" { value = google_service_account.workload.email }
output "kafka_ilb_ip" { value = google_compute_address.kafka_ilb.address }
output "ingress_ip" { value = var.gke_enabled ? google_compute_global_address.ingress[0].address : "" }
output "ingress_ip_name" { value = "s19-ingress-ip" }
output "dataproc_cluster" { value = var.dataproc_enabled ? google_dataproc_cluster.flink[0].name : "" }
output "dataproc_master_ip" {
  value = var.dataproc_enabled ? data.google_compute_instance.flink_master[0].network_interface[0].network_ip : ""
}
output "alert_function" { value = google_cloudfunctions2_function.alert.name }
output "github_wif_provider" { value = google_iam_workload_identity_pool_provider.github.name }
output "github_ci_service_account" { value = google_service_account.ci.email }
