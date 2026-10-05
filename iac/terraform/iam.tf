resource "google_service_account" "keycloak_gsa" {
  account_id   = "keycloak-gsa"
  display_name = "Keycloak Service Account"
  depends_on   = [google_project_service.project_apis]
}

resource "google_project_iam_member" "sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.keycloak_gsa.email}"
}

resource "google_service_account_iam_member" "workload_identity_user_keycloak" {
  service_account_id = google_service_account.keycloak_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[base-services/keycloak-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

resource "google_service_account" "bigtable_connector" {
  account_id   = "bigtable-connector"
  display_name = "Bigtable Connector Service Account"
  depends_on   = [google_project_service.project_apis]
}

resource "google_project_iam_member" "bigtable_connector_user" {
  project = var.project_id
  role    = "roles/bigtable.user"
  member  = "serviceAccount:${google_service_account.bigtable_connector.email}"
}

resource "google_service_account_iam_member" "workload_identity_user_bigtable_connector" {
  service_account_id = google_service_account.bigtable_connector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[base-services/nats-bigtable-connector-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

resource "google_service_account" "data_api_bigtable_connector" {
  account_id   = "data-api-bigtable-connector"
  display_name = "Data API to Bigtable Connector Service Account"
  depends_on   = [google_project_service.project_apis]
}

resource "google_project_iam_member" "data_api_bigtable_connector_user" {
  project = var.project_id
  role    = "roles/bigtable.reader"
  member  = "serviceAccount:${google_service_account.data_api_bigtable_connector.email}"
}

resource "google_project_iam_member" "data_api_bigtable_connector_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.data_api_bigtable_connector.email}"
}

resource "google_service_account_iam_member" "workload_identity_user_data_api_bigtable_connector" {
  service_account_id = google_service_account.data_api_bigtable_connector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[base-services/data-api-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

resource "google_service_account_iam_member" "workload_identity_user_data_web_client" {
  service_account_id = google_service_account.data_api_bigtable_connector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[sample-services/data-web-client-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

# vin-registry needs Cloud SQL access only, which this account already carries
# (roles/cloudsql.client above) — so it reuses it instead of adding another
# service account and another role binding.
resource "google_service_account_iam_member" "workload_identity_user_vin_registry" {
  service_account_id = google_service_account.data_api_bigtable_connector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[base-services/vin-registry-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

resource "google_service_account" "external_secrets_gsa" {
  account_id   = "external-secrets-gsa"
  display_name = "External Secrets Operator Service Account"
  depends_on   = [google_project_service.project_apis]
}

resource "google_project_iam_member" "external_secrets_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.external_secrets_gsa.email}"
}

resource "google_service_account_iam_member" "workload_identity_user_external_secrets" {
  service_account_id = google_service_account.external_secrets_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[base-services/external-secrets-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

# The data-web-client deploys its ExternalSecret and SecretStore in the sample-services
# namespace, so its external-secrets-ksa KSA also lives there.
resource "google_service_account_iam_member" "workload_identity_user_external_secrets_sample_services" {
  service_account_id = google_service_account.external_secrets_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[sample-services/external-secrets-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

resource "google_service_account" "registration_gsa" {
  account_id   = "registration-gsa"
  display_name = "Registration Server Service Account"
  depends_on   = [google_project_service.project_apis]
}

resource "google_project_iam_member" "registration_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.registration_gsa.email}"
}

resource "google_service_account_iam_member" "workload_identity_user_registration" {
  service_account_id = google_service_account.registration_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[base-services/registration-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

resource "google_service_account" "factory_helper_gsa" {
  account_id   = "factory-helper-gsa"
  display_name = "Factory Helper Service Account"
  depends_on   = [google_project_service.project_apis]
}

# The ONLY permission: request certificates from the factory CA pool.
# No Secret Manager access, no other roles — this isolation is the security model.
resource "google_privateca_ca_pool_iam_member" "factory_helper_requester" {
  # CA pools exist only with remote PKI (pki.tf creates them when is_remote).
  # With local PKI the pool path below resolves to nothing and the binding
  # fails with a 404, taking the whole bootstrap down.
  count = local.is_remote ? 1 : 0

  # The provider requires the fully-qualified pool path here — a bare pool name
  # plus separate location/project attributes is rejected.
  ca_pool = "projects/${var.project_id}/locations/${var.region}/caPools/${var.existing_factory_ca_pool != "" ? var.existing_factory_ca_pool : var.created_factory_ca_pool}"
  role    = "roles/privateca.certificateRequester"
  member  = "serviceAccount:${google_service_account.factory_helper_gsa.email}"
}

resource "google_service_account_iam_member" "workload_identity_user_factory_helper" {
  service_account_id = google_service_account.factory_helper_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[factory/factory-helper-ksa]"
  depends_on         = [google_container_cluster.gke_cluster]
}

output "keycloak_sa_id" {
  value       = google_service_account.keycloak_gsa.account_id
  description = "The ID of the Keycloak Service Account"
}

output "external_secrets_sa_id" {
  value       = google_service_account.external_secrets_gsa.account_id
  description = "The ID of the External Secrets Operator Service Account"
}

output "bigtable_connector_sa_id" {
  value       = google_service_account.bigtable_connector.account_id
  description = "The ID of the Bigtable Connector Service Account"
}

output "data_api_bigtable_connector_sa_id" {
  value       = google_service_account.data_api_bigtable_connector.account_id
  description = "The ID of the Data API Bigtable Connector Service Account"
}
