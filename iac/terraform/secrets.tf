# This file manages the application secrets in GCP Secret Manager.

# A map of secrets that will be created in Secret Manager.
# Expected keys (managed via External Secrets Operator):
#   - nats-server-user: NATS basic auth username
#   - nats-server-password: NATS basic auth password
#   - nats-auth-callout-nkey-pub: NATS auth callout NKey public key
#   - jwt-acc-signing-key: JWT account signing key
#   - keycloak-jwk-b64: Keycloak JWK in base64
#   - nats-url: Full NATS connection URL
#   - keycloak-tls-crt: Keycloak TLS certificate
#   - keycloak-tls-key: Keycloak TLS private key
#   - keycloak-admin-password: Keycloak admin password
#   - keycloak-truststore-ca: Keycloak truststore CA certificate
#   - keycloak-db-password: Keycloak database password (auto-generated in sql.tf)
#   - keycloak-instance-con-sql-proxy: Cloud SQL Proxy instance connection name
#   - keycloak-gcp-service-account: Keycloak GCP service account email
#   - registration-server-cert: Registration server TLS certificate
#   - registration-server-key: Registration server TLS private key
#   - registration-ca-cert: Registration CA certificate for signing operational certificates
#   - registration-ca-key: Registration CA private key (LOCAL mode only)
#   - registration-factory-ca-cert: Factory CA certificate for vehicle authentication
variable "platform_secrets" {
  description = "A map of application secrets to be stored in GCP Secret Manager."
  type        = map(string)
  sensitive   = true
  default     = {}
}

# Create a local, explicitly non-sensitive set of the secret keys.
# This is a robust way to avoid the "Invalid for_each argument" error that can
# occur when Terraform's sensitivity analysis is overly aggressive.
locals {
  secret_keys = nonsensitive(toset(keys(var.platform_secrets)))
}

# Create a secret in Secret Manager for each entry in the var.platform_secrets map
resource "google_secret_manager_secret" "secrets" {
  # Use the non-sensitive local variable for the for_each loop
  for_each  = local.secret_keys
  project   = var.project_id
  secret_id = "${var.environment}-${each.key}" # e.g., "dev-nats-server-user"

  replication {
    auto {}
  }

  labels = {
    "managed-by" = "terraform"
  }
}

# Add a version with the secret data to each created secret
resource "google_secret_manager_secret_version" "secret_versions" {
  for_each = google_secret_manager_secret.secrets
  secret   = each.value.id
  # NOTE: Using the write-only attribute to prevent the secret value from being
  # stored in the Terraform state file, resolving the validation warning.
  secret_data_wo = var.platform_secrets[each.key]
}

# Hostname secrets - these are non-sensitive configuration values
resource "google_secret_manager_secret" "keycloak_hostname" {
  project   = var.project_id
  secret_id = "${var.environment}-keycloak-hostname"

  replication {
    auto {}
  }

  labels = {
    "managed-by" = "terraform"
  }
}

resource "google_secret_manager_secret_version" "keycloak_hostname_version" {
  secret      = google_secret_manager_secret.keycloak_hostname.id
  secret_data = var.keycloak_hostname
}

resource "google_secret_manager_secret" "nats_hostname" {
  project   = var.project_id
  secret_id = "${var.environment}-nats-hostname"

  replication {
    auto {}
  }

  labels = {
    "managed-by" = "terraform"
  }
}

resource "google_secret_manager_secret_version" "nats_hostname_version" {
  secret      = google_secret_manager_secret.nats_hostname.id
  secret_data = var.nats_hostname
}

resource "google_secret_manager_secret" "registration_hostname" {
  project   = var.project_id
  secret_id = "${var.environment}-registration-hostname"

  replication {
    auto {}
  }

  labels = {
    "managed-by" = "terraform"
  }
}

resource "google_secret_manager_secret_version" "registration_hostname_version" {
  secret      = google_secret_manager_secret.registration_hostname.id
  secret_data = var.registration_hostname
}
