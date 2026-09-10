# Separate datasets, not prefixed table names, so access can be granted per layer.
locals {
  datasets = {
    raw = {
      description = "Landing zone. Truncated and reloaded with the current daily export on every run; holds the last snapshot only. The durable archive is the GCS landing bucket."
    }
    stage = {
      description = "Typed, deduplicated daily snapshots, partitioned by dt. Retains full history so any run date can be replayed into core."
    }
    core = {
      description = "Curated, query-ready Jira issues. SCD1: one row per id, latest state wins via MERGE."
    }
    dq = {
      description = "Data quality findings from the monitoring-tier checks."
    }
  }
}

resource "google_bigquery_dataset" "this" {
  for_each = local.datasets

  dataset_id  = each.key
  project     = var.project_id
  location    = var.bq_location
  description = each.value.description
  labels      = merge(local.common_labels, { layer = each.key })

  # Dropping a dataset has to be a deliberate two-step.
  delete_contents_on_destroy = false
}
