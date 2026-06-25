resource "google_artifact_registry_repository" "artifact_registry" {
  project       = var.project_id
  location      = var.region
  repository_id = "artifact-registry"
  description   = "A registry to store the docker images"
  format        = "DOCKER"
  depends_on    = [google_project_service.project_apis]
}

# Remote repository that proxies Docker Hub so Cloud Build workers can pull
# standard base images (golang, alpine, rust) without hitting Docker Hub
# rate limits and without leaving the project's network egress path.
resource "google_artifact_registry_repository" "docker_hub_proxy" {
  project       = var.project_id
  location      = var.region
  repository_id = "docker-hub"
  description   = "Remote repository proxying Docker Hub for base image caching"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.project_apis]
}

output "artifact_registry_id" {
  value = google_artifact_registry_repository.artifact_registry.repository_id
}