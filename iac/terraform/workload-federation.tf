locals {
  workload_identity_pool_id                   = "${var.wif_pool_id}"
  workload_identity_pool_description          = "Github Workload Identity Federation Pool"
  workload_identity_pool_provider_id          = "${var.wif_provider_id}"
  workload_identity_pool_provider_description = "Github Workload Identity Federation Pool Provider"
}

resource "google_iam_workload_identity_pool" "workload-identity-pool" {
  workload_identity_pool_id = local.workload_identity_pool_id
  display_name              = local.workload_identity_pool_id
  description               = local.workload_identity_pool_description
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "workload-identity-provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.workload-identity-pool.workload_identity_pool_id
  workload_identity_pool_provider_id = local.workload_identity_pool_provider_id
  display_name                       = local.workload_identity_pool_provider_id
  description                        = local.workload_identity_pool_provider_description
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  // Enter your specific GitHub organization. This settings ensures, that workflows
  // only from your GitHub Organization are able to make changes in Google Cloud
  attribute_condition = <<EOT
    attribute.repository.startsWith("${var.github_org}")
    EOT
  project             = var.project_id

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "oidc-sa" {
  account_id   = "${var.environment}-sa-github-oidc"
  display_name = "${var.environment}-sa-github-oidc"
  description  = "Service Account for Github OIDC used for operations"
  project      = var.project_id
}

resource "time_sleep" "wait_for_iam_propagation" {
  # Wait for 30 seconds. You may need to adjust this time.
  create_duration = "30s"

  # Explicitly depend on the pool
  depends_on = [google_iam_workload_identity_pool.workload-identity-pool]
}

resource "google_project_iam_member" "oidc-sa-iam-sdv" {
  project = var.project_id
  role    = "roles/iam.workloadIdentityUser"
  member  = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.workload-identity-pool.name}/attribute.repository/${var.repository}"
  depends_on = [time_sleep.wait_for_iam_propagation]
}


resource "google_project_iam_member" "oidc-project-iam" {
  project = var.project_id
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.oidc-sa.email}"
}

resource "google_project_iam_member" "sa_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.oidc-sa.email}"
}

resource "google_project_iam_member" "sa_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.oidc-sa.email}"
}

output "service_account_email" {
  description = "The email of the service account for GitHub OIDC."
  value       = google_service_account.oidc-sa.email
}

output "random_suffix" {
  value = var.random_suffix
}