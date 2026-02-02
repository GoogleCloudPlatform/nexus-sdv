locals {
  use_existing_dns_zone = var.pki_strategy == "remote" && var.existing_dns_zone != ""
  create_dns_zone       = var.pki_strategy == "remote" && var.existing_dns_zone == ""
}

# Create new DNS zone only if not using existing
resource "google_dns_managed_zone" "sdv_zone" {
  count       = local.create_dns_zone ? 1 : 0

  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = "Managed by Terraform for Nexus SDV"
  visibility  = "public"
  project     = var.project_id

  depends_on = [google_project_service.remote_apis]
}

# Reference existing DNS zone if provided
data "google_dns_managed_zone" "existing_zone" {
  count   = local.use_existing_dns_zone ? 1 : 0
  name    = var.existing_dns_zone
  project = var.project_id
}

# Output nameservers from whichever zone we're using
output "name_servers" {
  description = "Nameservers to configure at your registrar"
  value = local.use_existing_dns_zone ? data.google_dns_managed_zone.existing_zone[0].name_servers : (
    local.create_dns_zone ? google_dns_managed_zone.sdv_zone[0].name_servers : []
  )
}