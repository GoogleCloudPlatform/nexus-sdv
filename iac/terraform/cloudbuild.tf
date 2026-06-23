locals {
  cloudbuild_roles = var.enable_github_oidc ? [] : [
    "roles/container.developer",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountUser",
    "roles/logging.logWriter",
    "roles/storage.admin",
    "roles/artifactregistry.writer",
    "roles/privateca.caManager",
    "roles/privateca.certificateManager",
    "roles/resourcemanager.projectIamAdmin",
  ]
}

# Cloud Build triggers must specify a user-managed or Compute Engine default SA —
# the legacy @cloudbuild SA is rejected by the API. Triggers in this project use
# PROJECT_NUMBER-compute@developer.gserviceaccount.com, so grant it the roles
# Cloud Build jobs need. roles/owner is required for the bootstrap run, which
# executes Terraform against all project resources.
resource "google_project_iam_member" "compute_sa_cloudbuild_roles" {
  for_each = toset(local.cloudbuild_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "compute_sa_owner" {
  count = var.enable_github_oidc ? 0 : 1

  project = var.project_id
  role    = "roles/owner"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"

  # Prevent Terraform destroy from revoking the owner binding.
  # The Compute SA uses this role to run Cloud Build jobs (including teardown
  # itself). If the binding is removed mid-destroy, all subsequent IAM and
  # resource deletions fail with 403. The binding is harmless to leave in place
  # since it only applies while the project exists.
  lifecycle {
    prevent_destroy = true
  }
}
