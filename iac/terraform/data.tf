# central source of data
data "google_project" "current" {
  project_id = var.project_id
}
