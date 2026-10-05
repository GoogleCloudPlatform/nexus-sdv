# Custom metrics + dashboard visualizing platform-health-check.sh
# (--report-metrics) output.
#
# "section" distinguishes each check's own point (section=apis, ...) from
# the per-environment total (section=all).

locals {
  platform_health_metric_labels = {
    environment = "Bootstrap environment label (e.g. sandbox)."
    section     = "Check section name (e.g. nodes), or \"all\" for the per-environment total."
  }

  platform_health_fail_detail_labels = merge(local.platform_health_metric_labels, {
    message = "The recorded failure text (truncated to 500 characters)."
  })

  platform_health_counts = {
    pass = "Pass"
    warn = "Warning"
    fail = "Failure"
  }
}

resource "google_monitoring_metric_descriptor" "platform_health_count" {
  for_each = local.platform_health_counts

  type         = "custom.googleapis.com/platform_health/${each.key}_count"
  metric_kind  = "GAUGE"
  value_type   = "INT64"
  unit         = "1"
  display_name = "Platform health: ${each.key} count"
  description  = "${each.value} count from a platform-health-check.sh run, per environment/section."

  dynamic "labels" {
    for_each = local.platform_health_metric_labels
    content {
      key         = labels.key
      value_type  = "STRING"
      description = labels.value
    }
  }
}

resource "google_monitoring_metric_descriptor" "platform_health_fail_detail" {
  type         = "custom.googleapis.com/platform_health/fail_detail"
  metric_kind  = "GAUGE"
  value_type   = "INT64"
  unit         = "1"
  display_name = "Platform health: fail detail"
  description  = "One point per reported failure from a platform-health-check.sh run — value 1 while active, 0 once resolved; the failure text is carried in the message label."

  dynamic "labels" {
    for_each = local.platform_health_fail_detail_labels
    content {
      key         = labels.key
      value_type  = "STRING"
      description = labels.value
    }
  }
}

resource "google_monitoring_dashboard" "platform_health" {
  dashboard_json = file("${path.module}/templates/platform_health_dashboard.json")

  depends_on = [
    google_monitoring_metric_descriptor.platform_health_count,
    google_monitoring_metric_descriptor.platform_health_fail_detail,
  ]
}

output "platform_health_dashboard_url" {
  value = "https://console.cloud.google.com/monitoring/dashboards/builder/${google_monitoring_dashboard.platform_health.id}?project=${var.project_id}"
}
