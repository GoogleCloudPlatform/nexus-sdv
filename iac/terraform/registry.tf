resource "google_artifact_registry_repository" "artifact_registry" {
  project       = var.project_id
  location      = var.region
  repository_id = "artifact-registry"
  description   = "A registry to store the docker images"
  format        = "DOCKER"
  depends_on    = [google_project_service.project_apis]
}