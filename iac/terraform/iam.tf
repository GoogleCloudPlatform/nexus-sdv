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
