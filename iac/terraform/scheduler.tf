# Cloud Scheduler job that runs the platform-health-check Cloud Build trigger
# 3x/day. Renaming or deleting the trigger outside Terraform breaks this job
# silently — check Cloud Scheduler's own execution logs, not Terraform, if
# scheduled runs stop showing up.

resource "google_cloud_scheduler_job" "platform_health_check" {
  # Follows the trigger it invokes: no trigger, no schedule.
  count       = var.cloudbuild_repo_resource == "" ? 0 : 1
  name        = "platform-health-check"
  description = "Runs the platform-health-check Cloud Build trigger 3x/day (--report-metrics on, --e2e off)."
  region      = var.region
  schedule    = "0 0,8,16 * * *"
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/triggers/platform-health-check:run"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      source = {
        branchName = "main"
        substitutions = {
          _RUN_E2E        = "N"
          _REPORT_METRICS = "Y"
        }
      }
    }))

    oauth_token {
      service_account_email = local.default_compute_sa
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloudbuild_trigger.platform_health_check]
}
