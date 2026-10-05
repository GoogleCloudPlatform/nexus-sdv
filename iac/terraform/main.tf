terraform {
  backend "gcs" {}
  required_version = ">= 1.11.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.31.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  project_apis = [
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "run.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "iap.googleapis.com",
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "discoveryengine.googleapis.com",
    "certificatemanager.googleapis.com",
    "container.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "monitoring.googleapis.com",
    "cloudscheduler.googleapis.com",
    "bigtableadmin.googleapis.com"
  ]
}

resource "google_project_service" "project_apis" {
  for_each = toset(local.project_apis)
  service  = each.value

  # The teardown deletes Secret Manager entries, CA pools and DNS records AFTER
  # terraform destroy. Disabling the APIs here made every one of those calls
  # fail, so the next bootstrap in the same project inherited the previous
  # environment's secrets (ENV, GKE_CLUSTER_NAME) and deployed against a cluster
  # that no longer existed.
  disable_on_destroy = false
}

data "google_project" "project" {
  project_id = var.project_id
}

locals {
  remote_apis = var.pki_strategy == "remote" ? toset([
    "dns.googleapis.com",
    "privateca.googleapis.com"
  ]) : toset([])
}

resource "google_project_service" "remote_apis" {
  for_each           = local.remote_apis
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}
