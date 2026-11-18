# Zonal GKE Standard cluster: the $74.40/month GKE free-tier credit covers the management fee
# of one zonal (or Autopilot) cluster per billing account. Nodes are billed as Compute Engine VMs.
resource "google_container_cluster" "s19" {
  count    = var.gke_enabled ? 1 : 0
  name     = "s19-gke"
  location = var.zone

  network         = google_compute_network.vpc.id
  subnetwork      = google_compute_subnetwork.main.id
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  release_channel { channel = "REGULAR" }
  workload_identity_config { workload_pool = "${var.project_id}.svc.id.goog" }

  addons_config {
    http_load_balancing { disabled = false }        # GKE Ingress controller (public URL)
    horizontal_pod_autoscaling { disabled = false } # HPA
  }

  # Centralised logging: container stdout/stderr of every pod -> Cloud Logging (50 GiB/project/month free)
  logging_config { enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"] }

  # We run our own Prometheus, so Google Managed Prometheus collection is disabled (it bills per sample)
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus { enabled = false }
  }

  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "primary" {
  count    = var.gke_enabled ? 1 : 0
  name     = "primary"
  cluster  = google_container_cluster.s19[0].id
  location = var.zone

  initial_node_count = var.gke_min_nodes
  autoscaling {
    min_node_count = var.gke_min_nodes
    max_node_count = var.gke_max_nodes
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.gke_machine_type
    disk_type       = "pd-standard"
    disk_size_gb    = 30
    spot            = var.use_spot_nodes
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = { app = "s19" }
    workload_metadata_config { mode = "GKE_METADATA" }
  }

  lifecycle { ignore_changes = [initial_node_count] }
}
