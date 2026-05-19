

variables {
  project_id            = "sdv-sandbox"
  region                = "europe-west3"
  zone                  = "europe-west3-a"
  environment           = "sandbox"
  repository            = "https://github.com/DE-Nexus-SDV/valtech-sdv-sandbox.git"
  random_suffix         = "test-suffix"
  github_org            = "DE-Nexus-SDV"
  keycloak_hostname     = "keycloak"
  nats_hostname         = "nats"
  registration_hostname = "registration"
  base_domain           = "sdv-dae.net"
  wif_pool_id           = "wifpoolci"
}
# Set Provider Configuration inside the test file explicitly to avoid project not reached error
override_data {
  target = data.google_project.current
  values = {
    number = "1091310547571" # Mock the data so it doesn't try to call the API
  }
}

override_data {
  target = data.google_project.project
  values = {
    number = "1091310547571"
  }
}

run "test_terraform_plan" {
  command = plan

  # Bigtable
  assert {
    condition     = google_bigtable_instance.production_instance.name == output.bigtable_instance_name
    error_message = "Bigtable instance name incorrect"
  }
  assert {
    condition     = google_bigtable_table.table.name == output.bigtable_table_name
    error_message = "Bigtable table name incorrect"
  }

  # GKE
  assert {
    condition     = google_container_cluster.gke_cluster.name == output.gke_cluster_name
    error_message = "GKE cluster name incorrect"
  }
  assert {
    condition     = google_container_cluster.gke_cluster.enable_autopilot == output.gke_autopilot_enabled
    error_message = "GKE autopilot should be enabled"
  }

  # IAM Service Accounts
  assert {
    condition     = google_service_account.keycloak_gsa.account_id == output.keycloak_sa_id
    error_message = "Keycloak SA ID incorrect"
  }
  assert {
    condition     = google_service_account.bigtable_connector.account_id == output.bigtable_connector_sa_id
    error_message = "Bigtable Connector SA ID incorrect"
  }
  assert {
    condition     = google_service_account.data_api_bigtable_connector.account_id == output.data_api_bigtable_connector_sa_id
    error_message = "Data API Bigtable Connector SA ID incorrect"
  }
  assert {
    condition     = google_service_account.oidc-sa.account_id == output.oidc_sa_id
    error_message = "OIDC SA ID incorrect"
  }

  # Network
  assert {
    condition     = google_compute_network.vpc.name == output.vpc_name
    error_message = "VPC name incorrect"
  }
  assert {
    condition     = google_compute_subnetwork.subnet.name == output.subnet_name
    error_message = "Subnet name incorrect"
  }
  assert {
    condition     = google_compute_router.router.name == output.router_name
    error_message = "Router name incorrect"
  }
  assert {
    condition     = google_compute_router_nat.nat.name == output.nat_name
    error_message = "NAT name incorrect"
  }

  # Registry
  assert {
    condition     = google_artifact_registry_repository.artifact_registry.repository_id == output.artifact_registry_id
    error_message = "Artifact Registry ID incorrect"
  }

  # SQL
  assert {
    condition     = google_sql_database_instance.sql_db.name == output.sql_instance_name
    error_message = "SQL instance name incorrect"
  }
  assert {
    condition     = google_sql_database.database_keycloak.name == output.sql_database_name
    error_message = "SQL database name incorrect"
  }
  assert {
    condition     = google_sql_user.keycloak_user.name == output.sql_user_name
    error_message = "SQL user name incorrect"
  }

  # Workload Federation
  assert {
    condition     = google_iam_workload_identity_pool.workload-identity-pool.workload_identity_pool_id == output.workload_identity_pool_id
    error_message = "Workload Identity Pool ID incorrect"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.workload-identity-provider.workload_identity_pool_provider_id == output.workload_identity_pool_provider_id
    error_message = "Workload Identity Pool Provider ID incorrect"
  }
}
