# Composer itself is managed elsewhere; only the grants the DAG depends on are
# declared here, so a missing one shows up as a diff rather than a 403.
locals {
  grant_pipeline_sa = var.pipeline_service_account != null
  sa_member         = local.grant_pipeline_sa ? "serviceAccount:${var.pipeline_service_account}" : null
}

resource "google_storage_bucket_iam_member" "pipeline_landing_reader" {
  count = local.grant_pipeline_sa ? 1 : 0

  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectViewer"
  member = local.sa_member
}

# Per-dataset, so the SA cannot touch unrelated datasets.
resource "google_bigquery_dataset_iam_member" "pipeline_data_editor" {
  for_each = local.grant_pipeline_sa ? local.datasets : {}

  project    = var.project_id
  dataset_id = google_bigquery_dataset.this[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = local.sa_member
}

# jobUser is project-level but conveys no data access; the grants above are the boundary.
resource "google_project_iam_member" "pipeline_job_user" {
  count = local.grant_pipeline_sa ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = local.sa_member
}
