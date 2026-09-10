# Landing pad, not an archive: WRITE_TRUNCATE leaves the latest snapshot only,
# which is why 01_stage_load.sql reads it with no WHERE clause.
resource "google_bigquery_table" "raw_jira_issues" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.this["raw"].dataset_id
  table_id            = "jira_issues"
  schema              = file("${path.module}/schemas/raw_jira_issues.json")
  deletion_protection = var.deletion_protection

  description = "Current daily Jira export, loaded with WRITE_TRUNCATE. Last snapshot only; the durable archive is gs://${var.landing_bucket_name}/jira_exports/."
  labels      = merge(local.common_labels, { layer = "raw" })
}

# Full snapshot history. require_partition_filter stops a query scanning every
# day of it.
resource "google_bigquery_table" "stage_jira_issues" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.this["stage"].dataset_id
  table_id            = "jira_issues"
  schema              = file("${path.module}/schemas/stage_jira_issues.json")
  deletion_protection = var.deletion_protection

  require_partition_filter = true

  time_partitioning {
    type          = "DAY"
    field         = "dt"
    expiration_ms = var.stage_partition_expiration_days == null ? null : var.stage_partition_expiration_days * 24 * 60 * 60 * 1000
  }

  description = "Typed, deduplicated daily Jira snapshots. One partition per run date; retains full history."
  labels      = merge(local.common_labels, { layer = "stage" })
}

# Curated SCD1 table. Unpartitioned by design -- see RETENTION_AND_EVOLUTION.md.
resource "google_bigquery_table" "core_jira_issues" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.this["core"].dataset_id
  table_id            = "jira_issues"
  schema              = file("${path.module}/schemas/core_jira_issues.json")
  deletion_protection = var.deletion_protection

  clustering = ["id", "project"]

  description = "Curated, query-ready Jira issues. SCD1: one row per id, latest state wins via MERGE."
  labels      = merge(local.common_labels, { layer = "core" })
}

# dq_metrics: observations, written every run. dq_findings: violations only.
# metric_name / check_name are unique within a layer, not globally.
resource "google_bigquery_table" "dq_metrics" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.this["dq"].dataset_id
  table_id            = "dq_metrics"
  schema              = file("${path.module}/schemas/dq_metrics.json")
  deletion_protection = var.deletion_protection

  time_partitioning {
    type          = "DAY"
    field         = "run_date"
    expiration_ms = var.dq_partition_expiration_days * 24 * 60 * 60 * 1000
  }

  description = "Pipeline observations per run: row counts, dedup volumes, freshness. No pass/fail -- see dq_findings for that."
  labels      = merge(local.common_labels, { layer = "dq" })
}

resource "google_bigquery_table" "dq_findings" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.this["dq"].dataset_id
  table_id            = "dq_findings"
  schema              = file("${path.module}/schemas/dq_findings.json")
  deletion_protection = var.deletion_protection

  time_partitioning {
    type          = "DAY"
    field         = "run_date"
    expiration_ms = var.dq_partition_expiration_days * 24 * 60 * 60 * 1000
  }

  description = "DQ rule violations. Only failures are recorded, so any row here is a problem. severity=HIGH fails the pipeline; MEDIUM/LOW are recorded only."
  labels      = merge(local.common_labels, { layer = "dq" })
}
