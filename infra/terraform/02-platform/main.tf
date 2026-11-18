# 02-platform: bootstraps the cluster for GitOps.
#   * namespaces, Workload-Identity KSA, cloud config ConfigMap, DB/admin secrets   (cluster plumbing)
#   * Argo CD (Helm) + the root "app-of-apps" Application that points at this Git repo
# After this apply, EVERY workload (Kafka, monitoring, the 8 services) is deployed by Argo CD from Git.
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google     = { source = "hashicorp/google", version = "~> 6.14" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "gcs" {
    prefix = "s19/02-platform"
  }
}

variable "project_id" { type = string }
variable "tfstate_bucket" { type = string }
variable "git_repo_url" {
  type        = string
  description = "HTTPS URL of the GitHub repo Argo CD tracks, e.g. https://github.com/me/s19-disaster-management.git"
}
variable "git_revision" {
  type    = string
  default = "main"
}
variable "git_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Only for a PRIVATE repo: GitHub fine-grained token with read-only Contents permission"
}

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = var.tfstate_bucket
    prefix = "s19/01-foundation"
  }
}

locals {
  f = data.terraform_remote_state.foundation.outputs
}

provider "google" {
  project = var.project_id
  region  = local.f.region
}

data "google_client_config" "me" {}

data "google_container_cluster" "s19" {
  name     = local.f.gke_cluster_name
  location = local.f.zone
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.s19.endpoint}"
  token                  = data.google_client_config.me.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.s19.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.google_container_cluster.s19.endpoint}"
    token                  = data.google_client_config.me.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.s19.master_auth[0].cluster_ca_certificate)
  }
}

# ---------------------------------------------------------------- namespaces
resource "kubernetes_namespace_v1" "ns" {
  for_each = toset(["s19", "kafka", "monitoring"])
  metadata {
    name   = each.value
    labels = { "app.kubernetes.io/part-of" = "s19" }
  }
}

# ---------------------------------------------------------------- identity + config for the services
resource "kubernetes_service_account_v1" "app" {
  metadata {
    name        = "s19-app"
    namespace   = "s19"
    annotations = { "iam.gke.io/gcp-service-account" = local.f.workload_gsa_email }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "kubernetes_config_map_v1" "cloud" {
  metadata {
    name      = "s19-cloud-config"
    namespace = "s19"
  }
  data = {
    GCP_PROJECT_ID     = var.project_id
    RAW_BUCKET         = local.f.data_bucket
    ALERT_TOPIC        = local.f.alert_topic
    FIRESTORE_DATABASE = local.f.firestore_database
    DB_HOST            = local.f.cloudsql_private_ip
    DB_NAME            = local.f.cloudsql_db_name
    DB_USER            = local.f.cloudsql_user
    KAFKA_BOOTSTRAP    = "kafka.kafka.svc.cluster.local:9092"
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "random_password" "admin_token" {
  length  = 20
  special = false
}

resource "kubernetes_secret_v1" "app" {
  metadata {
    name      = "s19-secrets"
    namespace = "s19"
  }
  data = {
    DB_PASSWORD = local.f.cloudsql_password
    ADMIN_TOKEN = random_password.admin_token.result
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "random_password" "grafana" {
  length  = 16
  special = false
}

resource "kubernetes_secret_v1" "grafana" {
  metadata {
    name      = "grafana-admin"
    namespace = "monitoring"
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

# Flink metrics live on the Dataproc VM; a selector-less Service + Endpoints gives Prometheus
# a stable in-cluster name (flink-metrics.monitoring.svc) for that external target.
resource "kubernetes_service_v1" "flink_metrics" {
  count = local.f.dataproc_master_ip == "" ? 0 : 1
  metadata {
    name      = "flink-metrics"
    namespace = "monitoring"
  }
  spec {
    port {
      name        = "jm"
      port        = 9250
      target_port = 9250
    }
    port {
      name        = "tm"
      port        = 9251
      target_port = 9251
    }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "kubernetes_endpoints_v1" "flink_metrics" {
  count = local.f.dataproc_master_ip == "" ? 0 : 1
  metadata {
    name      = "flink-metrics"
    namespace = "monitoring"
  }
  subset {
    address { ip = local.f.dataproc_master_ip }
    port {
      name = "jm"
      port = 9250
    }
    port {
      name = "tm"
      port = 9251
    }
  }
  depends_on = [kubernetes_service_v1.flink_metrics]
}

# ---------------------------------------------------------------- Argo CD
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.5.15"
  timeout          = 900
  values           = [file("${path.module}/argocd-values.yaml")]
}

resource "kubernetes_secret_v1" "repo" {
  count = var.git_token == "" ? 0 : 1
  metadata {
    name      = "s19-repo"
    namespace = "argocd"
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }
  data = {
    type     = "git"
    url      = var.git_repo_url
    username = "git"
    password = var.git_token
  }
  depends_on = [helm_release.argocd]
}

# Root Application (app-of-apps). Everything below deploy/argocd/apps is synced from Git.
resource "helm_release" "argocd_root" {
  name       = "s19-root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"
  values = [yamlencode({
    applications = {
      s19-root = {
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.git_repo_url
          targetRevision = var.git_revision
          path           = "deploy/argocd/apps"
          directory      = { recurse = false }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=false"]
        }
      }
    }
  })]
  depends_on = [helm_release.argocd, kubernetes_secret_v1.repo, kubernetes_config_map_v1.cloud,
  kubernetes_secret_v1.app, kubernetes_service_account_v1.app, kubernetes_secret_v1.grafana]
}

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}
output "admin_token" {
  value     = random_password.admin_token.result
  sensitive = true
}
output "argocd_initial_password_cmd" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
