# VPC with one subnet. Secondary ranges make GKE VPC-native (pods get routable VPC IPs, which
# lets Prometheus in GKE scrape the Dataproc VM and lets Dataproc reach Kafka's internal LB).
resource "google_compute_network" "vpc" {
  name                    = "s19-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name                     = "s19-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true # Dataproc VM has no external IP but must reach GCS / Logging APIs

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

resource "google_compute_firewall" "allow_internal" {
  name          = "s19-allow-internal"
  network       = google_compute_network.vpc.name
  source_ranges = ["10.10.0.0/20", "10.20.0.0/16"]
  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# IAP TCP forwarding range: lets you `gcloud compute ssh --tunnel-through-iap` into the Dataproc VM
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "s19-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Private Service Access: Cloud SQL gets a private IP inside our VPC (no public IP, no proxy needed)
resource "google_compute_global_address" "psa" {
  name          = "s19-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
  deletion_policy         = "ABANDON" # avoids "producer services still using this connection" on destroy
}

# Static internal IP for the Kafka internal passthrough load balancer (Dataproc -> Kafka on GKE)
resource "google_compute_address" "kafka_ilb" {
  name         = "s19-kafka-ilb"
  region       = var.region
  subnetwork   = google_compute_subnetwork.main.id
  address_type = "INTERNAL"
  address      = var.kafka_ilb_ip
}

# Static global external IP for the public GKE Ingress (stable public URL for the demo).
# Tied to gke_enabled: an IP that is reserved but not attached to a forwarding rule is billed.
resource "google_compute_global_address" "ingress" {
  count      = var.gke_enabled ? 1 : 0
  name       = "s19-ingress-ip"
  depends_on = [google_project_service.apis]
}
