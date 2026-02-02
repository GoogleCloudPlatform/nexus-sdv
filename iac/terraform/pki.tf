locals {
  is_remote = var.pki_strategy == "remote"

  # Determine if we're using existing CAs or creating new ones
  use_existing_server_ca  = local.is_remote && var.existing_server_ca != ""
  use_existing_factory_ca = local.is_remote && var.existing_factory_ca != ""
  use_existing_reg_ca     = local.is_remote && var.existing_reg_ca != ""

  # Create new CAs only if we're remote AND not using existing
  create_server_ca  = local.is_remote && !local.use_existing_server_ca
  create_factory_ca = local.is_remote && !local.use_existing_factory_ca
  create_reg_ca     = local.is_remote && !local.use_existing_reg_ca
}

# --- 1. SERVER CA ---
# Create new CA pool only if not using existing
resource "google_privateca_ca_pool" "server_pool" {
  count    = local.create_server_ca ? 1 : 0
  name     = "${var.created_server_ca_pool}"
  location = var.region
  tier     = "DEVOPS"
  project  = var.project_id

  # DEVOPS tier does not support publishing CRLs.
  publishing_options {
    publish_ca_cert = true
    publish_crl     = false
  }
  depends_on = [google_project_service.remote_apis]
}

# Create new CA only if not using existing
resource "google_privateca_certificate_authority" "server_root" {
  count                    = local.create_server_ca ? 1 : 0
  pool                     = google_privateca_ca_pool.server_pool[0].name
  certificate_authority_id = "server-root-ca"
  location                 = var.region
  project                  = var.project_id
  config {
    subject_config {
      subject {
        common_name  = "Nexus Server Root CA"
        organization = "Nexus SDV"
      }
    }
    x509_config {
      ca_options { is_ca = true }
      key_usage {
        base_key_usage {
          cert_sign = true
          crl_sign  = true
        }
        # This CA is used for both server and client certificates.
        extended_key_usage {
          server_auth = true
          client_auth = true
        }
      }
    }
  }
  key_spec { algorithm = "RSA_PKCS1_4096_SHA256" }
  ignore_active_certificates_on_deletion = true
  deletion_protection = false
}

# Reference existing Server CA if provided
data "google_privateca_certificate_authority" "existing_server_ca" {
  count                    = local.use_existing_server_ca ? 1 : 0
  certificate_authority_id = var.existing_server_ca
  location                 = var.region
  pool                     = var.existing_server_ca_pool
  project                  = var.project_id
}

# --- 2. REGISTRATION CA ---
# Create new CA pool only if not using existing
resource "google_privateca_ca_pool" "reg_pool" {
  count    = local.create_reg_ca ? 1 : 0
  name     = "${var.created_reg_ca_pool}"
  location = var.region
  tier     = "DEVOPS"
  project  = var.project_id

  # DEVOPS tier does not support publishing CRLs.
  publishing_options {
    publish_ca_cert = true
    publish_crl     = false
  }
  depends_on = [google_project_service.remote_apis]
}

# Create new CA only if not using existing
resource "google_privateca_certificate_authority" "reg_root" {
  count                    = local.create_reg_ca ? 1 : 0
  pool                     = google_privateca_ca_pool.reg_pool[0].name
  certificate_authority_id = "registration-root-ca"
  location                 = var.region
  project                  = var.project_id
  config {
    subject_config {
      subject {
        common_name  = "Nexus Registration Root CA"
        organization = "Nexus SDV"
      }
    }
    x509_config {
      ca_options { is_ca = true }
      key_usage {
        base_key_usage {
          cert_sign = true
          crl_sign  = true
        }
        # This CA is used for both server and client certificates.
        extended_key_usage {
          server_auth = true
          client_auth = true
        }
      }
    }
  }
  key_spec { algorithm = "RSA_PKCS1_4096_SHA256" }
  ignore_active_certificates_on_deletion = true
  deletion_protection = false
}

# Reference existing Registration CA if provided
data "google_privateca_certificate_authority" "existing_reg_ca" {
  count                    = local.use_existing_reg_ca ? 1 : 0
  certificate_authority_id = var.existing_reg_ca
  location                 = var.region
  pool                     = var.existing_reg_ca_pool
  project                  = var.project_id
}

# --- 3. FACTORY CA ---
# Create new CA pool only if not using existing
resource "google_privateca_ca_pool" "factory_pool" {
  count    = local.create_factory_ca ? 1 : 0
  name     = "${var.created_factory_ca_pool}"
  location = var.region
  tier     = "DEVOPS"
  project  = var.project_id

  # DEVOPS tier does not support publishing CRLs.
  publishing_options {
    publish_ca_cert = true
    publish_crl     = false
  }
  depends_on = [google_project_service.remote_apis]
}

# Create new CA only if not using existing
resource "google_privateca_certificate_authority" "factory_root" {
  count                    = local.create_factory_ca ? 1 : 0
  pool                     = google_privateca_ca_pool.factory_pool[0].name
  certificate_authority_id = "factory-root-ca"
  location                 = var.region
  project                  = var.project_id
  config {
    subject_config {
      subject {
        common_name  = "Nexus Factory Root CA"
        organization = "Nexus Factory"
      }
    }
    x509_config {
      ca_options { is_ca = true }
      key_usage {
        base_key_usage {
          cert_sign = true
          crl_sign  = true
        }
        # Factory CA is specifically for client certificates (e.g., for devices).
        extended_key_usage {
          client_auth = true
        }
      }
    }
  }
  key_spec { algorithm = "RSA_PKCS1_4096_SHA256" }
  ignore_active_certificates_on_deletion = true
  deletion_protection = false
}

# Reference existing Factory CA if provided
data "google_privateca_certificate_authority" "existing_factory_ca" {
  count                    = local.use_existing_factory_ca ? 1 : 0
  certificate_authority_id = var.existing_factory_ca
  location                 = var.region
  pool                     = var.existing_factory_ca_pool
  project                  = var.project_id
}
