locals {
  cloudbuild_roles = var.enable_github_oidc ? [] : [
    "roles/container.developer",
    "roles/secretmanager.secretAccessor",
    "roles/iam.serviceAccountUser",
    "roles/logging.logWriter",
    "roles/storage.admin",
    "roles/artifactregistry.writer"
  ]
}

resource "google_project_iam_member" "cloudbuild_iam" {
  for_each = toset(local.cloudbuild_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "compute_sa_storage_fix" {
  count = var.enable_github_oidc ? 0 : 1

  project = var.project_id
  role    = "roles/owner"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}
