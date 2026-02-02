resource "google_bigtable_instance" "production_instance" {
  name = "bigtable-production-storage"
  # Deletion protection disabled for sandbox/dev environment to enable clean terraform destroy
  # This allows automated teardown without manual intervention and was added to fix race conditions
  # during platform teardown. WARNING: For production environments, set to true to prevent data loss.
  deletion_protection = false

  cluster {
    cluster_id   = "bigtable-production-cluster"
    zone         = var.zone
    num_nodes    = 1
    storage_type = "HDD"
  }
}

resource "google_bigtable_table" "table" {
  name          = "telemetry"
  instance_name = google_bigtable_instance.production_instance.name
  # Deletion protection disabled for sandbox/dev environment to enable clean terraform destroy
  # This allows automated teardown without manual intervention and was added to fix race conditions
  # during platform teardown. WARNING: For production environments, set to "PROTECTED" to prevent data loss.
  deletion_protection = "UNPROTECTED"

  column_family {
    family = "static"
  }

  column_family {
    family = "dynamic"
  }
}
