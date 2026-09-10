output "landing_bucket" {
  description = "Bucket the DAG's raw_load task reads the daily export from."
  value       = google_storage_bucket.landing.name
}

output "dataset_ids" {
  description = "Dataset ids by layer."
  value       = { for k, ds in google_bigquery_dataset.this : k => ds.dataset_id }
}

output "core_table" {
  description = "Fully-qualified curated table, for use in downstream tooling."
  value       = "${var.project_id}.${google_bigquery_table.core_jira_issues.dataset_id}.${google_bigquery_table.core_jira_issues.table_id}"
}

output "bq_location" {
  description = "Must match JIRA_BQ_LOCATION in the Composer environment's variables."
  value       = var.bq_location
}
