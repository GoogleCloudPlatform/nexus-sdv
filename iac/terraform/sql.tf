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
      enabled                        = strcontains(var.environment, "prod")
      start_time                     = "03:00"
      point_in_time_recovery_enabled = false
    }
  }

  deletion_protection = false
  depends_on = [google_project_service.project_apis, google_service_networking_connection.psc_connection]
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
  }
}

# Create the keycloak database user
resource "google_sql_user" "keycloak_user" {
  name            = "keycloak"
  instance        = google_sql_database_instance.sql_db.name
  password        = random_password.keycloak_db_user_password.result
  # Bootstrap re-runs have been observed planning a deletion of these SQL users,
  # causing a "role cannot be dropped because some objects depend on it" error.
  # The exact root cause is unknown — likely the SQL instance being replaced
  # (which would cascade to replacing all users), but the trigger has not been
  # identified. ABANDON prevents Terraform from calling users.delete so the
  # bootstrap can proceed; the SQL instance deletion handles user cleanup
  # server-side when the environment is torn down.
  deletion_policy = "ABANDON"

  depends_on = [google_sql_database.database_keycloak]
}

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
  value     = random_password.keycloak_db_user_password.result
  sensitive = true
}

output "sql_instance_name" {
  value = google_sql_database_instance.sql_db.name
}

output "sql_database_name" {
  value = google_sql_database.database_keycloak.name
}

output "sql_user_name" {
  value = google_sql_user.keycloak_user.name
}

# ==============================================================================
# Web Client (nexus_acl) database, user, and secrets
# ==============================================================================

resource "google_sql_database" "database_nexus_acl" {
  name     = "nexus_acl"
  instance = google_sql_database_instance.sql_db.name
  depends_on = [google_project_service.project_apis]
}

resource "random_password" "webclient_db_user_password" {
  length  = 32
  special = false
  keepers = {
    environment = var.environment
  }
}

resource "google_sql_user" "webclient_user" {
  name            = "webclient"
  instance        = google_sql_database_instance.sql_db.name
  password        = random_password.webclient_db_user_password.result
  deletion_policy = "ABANDON" # see keycloak_user for the reason
  depends_on      = [google_sql_database.database_nexus_acl]
}

resource "google_secret_manager_secret" "webclient_db_password" {
  secret_id = "WEBCLIENT_DB_PASSWORD"
  replication {
    auto {}
  }
  depends_on = [google_project_service.project_apis]
}

resource "google_secret_manager_secret_version" "webclient_db_password" {
  secret      = google_secret_manager_secret.webclient_db_password.id
  secret_data = random_password.webclient_db_user_password.result
  depends_on  = [google_sql_user.webclient_user]
}

# ==============================================================================
# Postgres superuser password — used by CloudBuild schema-init step to grant
# the webclient user access and create the vehicle_groups table.
# ==============================================================================

resource "random_password" "postgres_db_password" {
  length  = 32
  special = false
  keepers = {
    environment = var.environment
  }
}

# Updates the built-in postgres superuser password so CloudBuild can connect.
resource "google_sql_user" "postgres_user" {
  name            = "postgres"
  instance        = google_sql_database_instance.sql_db.name
  password        = random_password.postgres_db_password.result
  deletion_policy = "ABANDON" # see keycloak_user for the reason
}

resource "google_secret_manager_secret" "postgres_db_password" {
  secret_id = "POSTGRES_DB_PASSWORD"
  replication {
    auto {}
  }
  depends_on = [google_project_service.project_apis]
}

resource "google_secret_manager_secret_version" "postgres_db_password" {
  secret      = google_secret_manager_secret.postgres_db_password.id
  secret_data = random_password.postgres_db_password.result
  depends_on  = [google_sql_user.postgres_user]
}
