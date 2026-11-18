variable "project_id" {
  type        = string
  description = "GCP project id"
}

variable "region" {
  type    = string
  default = "us-central1" # Always Free GCS region; e2 + Dataproc + Cloud SQL available
}

variable "zone" {
  type    = string
  default = "us-central1-a" # zonal GKE cluster -> covered by the GKE free-tier credit
}

variable "firestore_location" {
  type        = string
  default     = "nam5" # United States multi-region (includes us-central1); free quota applies to (default) db
}

variable "github_repo" {
  type        = string
  description = "owner/name of the GitHub repo allowed to push images (Workload Identity Federation)"
}

# ---------------------------------------------------------------- cost switches
variable "gke_enabled" {
  type        = bool
  default     = true
  description = "false => GKE cluster + node pool are destroyed (destroy 02-platform first)"
}

variable "cloudsql_running" {
  type        = bool
  default     = true
  description = "false => Cloud SQL instance is STOPPED (activation_policy NEVER); data kept, only disk billed"
}

variable "dataproc_enabled" {
  type        = bool
  default     = false
  description = "true only while working on / demonstrating the Flink job"
}

variable "use_spot_nodes" {
  type        = bool
  default     = true
  description = "Spot VMs are ~50-80% cheaper but can be preempted; set false on demo day"
}

# ---------------------------------------------------------------- sizing
variable "gke_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "gke_min_nodes" {
  type    = number
  default = 2
}

variable "gke_max_nodes" {
  type    = number
  default = 3 # 3 x 2 vCPU + Dataproc 2 vCPU = 8 vCPU = free-trial concurrent-core limit
}

variable "dataproc_machine_type" {
  type    = string
  default = "e2-standard-2" # 8 GB RAM fits Flink JM + 1 TM on YARN; use e2-standard-4 if not on free trial
}

variable "dataproc_idle_ttl" {
  type    = string
  default = "7200s" # auto-delete the Flink cluster after 2 h with no running job (cost guard)
}

variable "kafka_ilb_ip" {
  type        = string
  default     = "10.10.0.100"
  description = "Static internal IP of the Kafka internal load balancer (must match deploy/platform/kafka)"
}

variable "flink_prometheus_jar" {
  type        = string
  default     = "../../../flink/lib/flink-metrics-prometheus-1.17.0.jar"
  description = "Local path of the Flink Prometheus reporter jar (downloaded by `make flink-reporter-jar`)"
}

variable "billing_account_id" {
  type        = string
  default     = ""
  description = "Optional: billing account id (XXXXXX-XXXXXX-XXXXXX) to create a budget alert"
}

variable "budget_amount_usd" {
  type    = number
  default = 25
}

variable "alert_webhook_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional HTTPS webhook (Slack/Discord incoming webhook or https://ntfy.sh/<topic>) the Alert Service also posts to"
}
