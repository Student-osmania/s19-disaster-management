terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google  = { source = "hashicorp/google", version = "~> 6.14" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.6" }
  }
  # bucket is passed at init time:  terraform init -backend-config="bucket=<PROJECT_ID>-s19-tfstate"
  backend "gcs" {
    prefix = "s19/01-foundation"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
