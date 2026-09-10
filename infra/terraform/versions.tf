terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Bucket supplied at init: -backend-config="bucket=<tf-state-bucket>"
  backend "gcs" {
    prefix = "sentinelone/jira-pipeline"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
