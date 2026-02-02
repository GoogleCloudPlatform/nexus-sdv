resource "google_sql_database_instance" "sql_db" {
  name             = "cloud-sql-${var.environment}"
  database_version = "POSTGRES_15"
  region           = var.region

  settings {
    tier = "db-f1-micro"

    # Enable IAM authentication for Cloud SQL Proxy
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    # IP configuration - allow Cloud SQL Proxy connections
    ip_configuration {
      # Enable public IP for Cloud SQL Proxy (uses IAM auth, not IP allowlist)
      ipv4_enabled = true

      # Note: Cloud SQL Proxy handles encryption in the tunnel
      # No authorized networks needed - IAM auth bypasses IP allowlist
    }

    # Enable backups
    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = false
    }
  }

  deletion_protection = false
  depends_on = [google_project_service.project_apis]
}

resource "google_sql_database" "database_keycloak" {
  name     = "keycloak"
  instance = google_sql_database_instance.sql_db.name

  # Removed dependency on google_sql_user.keycloak_user to break a circular dependency.
  # A database does not need a user to exist, but a user needs a database to be granted permissions on.
  depends_on = [
    google_project_service.project_apis
  ]
}

resource "random_password" "keycloak_db_user_password" {
  length  = 32
  special = false
  keepers = {
    environment = var.environment
    suffix      = var.random_suffix
  }
}

# Create the keycloak database user
resource "google_sql_user" "keycloak_user" {
  name        = "keycloak"
  instance    = google_sql_database_instance.sql_db.name
  password    = random_password.keycloak_db_user_password.result

  depends_on = [google_sql_database.database_keycloak]
}

# Note: If you need to destroy the keycloak user and encounter errors about owned objects,
# manually run the following SQL commands as the postgres user:
#   REASSIGN OWNED BY keycloak TO postgres;
#   DROP OWNED BY keycloak;

# Create the secret for the Keycloak DB password.
# This was changed from a data source to a resource to ensure the secret is created by Terraform,
# making the configuration self-contained and avoiding a dependency on the bootstrapping script.
resource "google_secret_manager_secret" "keycloak_db_password" {
  secret_id = "KEYCLOAK_DB_PASSWORD"
  replication {
    # Corrected from 'automatic = true' to the proper syntax for automatic replication.
    auto {}
  }
  depends_on = [google_project_service.project_apis]
}

# Store the password in Secret Manager
resource "google_secret_manager_secret_version" "keycloak_db_password" {
  secret      = google_secret_manager_secret.keycloak_db_password.id
  secret_data = random_password.keycloak_db_user_password.result

  depends_on = [google_sql_user.keycloak_user]
}

# Output the connection details (password will be marked as sensitive)
output "keycloak_db_user" {
  description = "Keycloak database username"
  value       = google_sql_user.keycloak_user.name
}

output "keycloak_db_password" {
  description = "Keycloak database password (sensitive)"
  # Corrected the reference to the random_password resource.
  # It was 'random_password.keycloak_db_password.result', but the resource is named 'keycloak_db_user_password'.
  value       = random_password.keycloak_db_user_password.result
  sensitive   = true
}
