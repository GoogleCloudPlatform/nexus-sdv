# External DNS IAM Configuration
#
# This file configures IAM permissions for External DNS using Workload Identity
# to automatically create and manage DNS records in Cloud DNS

# Grant DNS admin permissions directly to the Kubernetes service account
# using the new principal:// format recommended by Google
resource "google_project_iam_member" "external_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/external-dns/sa/external-dns"
}

# Output for reference
output "external_dns_workload_identity_member" {
  description = "Workload Identity member for External DNS"
  value       = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/external-dns/sa/external-dns"
}
