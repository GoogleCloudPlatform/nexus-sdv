# Get the project to access project number
data "google_project" "current" {
  project_id = var.project_id
}

# Construct the default Compute Engine service account email
locals {
  default_compute_sa = "${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

# Create a dedicated service account for GKE nodes
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.environment}-gke-nodes"
  display_name = "GKE Nodes Service Account for ${var.environment}"
  project      = var.project_id
}

resource "google_project_iam_member" "gke_sa_role" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${local.default_compute_sa}"
  depends_on = [google_project_service.project_apis]
}

resource "google_project_iam_member" "gke_sa_role_artifact" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${local.default_compute_sa}"
  depends_on = [google_project_service.project_apis]
}

resource "google_container_cluster" "gke_cluster" {
  project = var.project_id
  name    = "${var.environment}-gke"

  location                 = var.region
  enable_autopilot         = true
  enable_l4_ilb_subsetting = true

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  deletion_protection = false
  depends_on = [google_project_service.project_apis]

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    stack_type                    = "IPV4"
    services_secondary_range_name = google_compute_subnetwork.subnet.secondary_ip_range[0].range_name
    cluster_secondary_range_name  = google_compute_subnetwork.subnet.secondary_ip_range[1].range_name
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = "01:00"
    }
  }

  # Private cluster configuration
  # enable_private_nodes = true: Nodes have no public IP addresses (secure)
  # enable_private_endpoint = false: Control plane has BOTH private and public endpoints
  #   - Private endpoint: For in-cluster and VPC access
  #   - Public endpoint: For GCP infrastructure (Autopilot), Cloud Build, Cloud Shell, etc.
  #   - Public endpoint access is restricted by master_authorized_networks_config below
  # This is the standard configuration for private GKE clusters with Autopilot.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  # Master authorized networks configuration for private cluster security
  # gcp_public_cidrs_access_enabled = true allows GCP's infrastructure (Autopilot, Cloud Build, etc.)
  # to access the control plane. This is REQUIRED for Autopilot clusters to function properly.
  # Without this, Autopilot nodes cannot register with the control plane.
  # Additional security can be enforced through network policies and workload identity.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = true
  }

}
