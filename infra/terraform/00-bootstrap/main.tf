# 00-bootstrap: creates the GCS bucket that stores Terraform state for 01-foundation and 02-platform.
# Uses LOCAL state (chicken-and-egg). Run once:  terraform init && terraform apply -var project_id=<id>
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.14" }
  }
}

variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-s19-tfstate"
  location                    = upper(var.region) # regional bucket in us-central1 -> Always Free storage region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  versioning { enabled = true }
  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action { type = "Delete" }
  }
  depends_on = [google_project_service.storage]
}

output "tfstate_bucket" { value = google_storage_bucket.tfstate.name }
