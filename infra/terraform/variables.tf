variable "project_id" {
  description = "GCP project that owns the BigQuery datasets and the landing bucket."
  type        = string
}

variable "region" {
  description = "Default region for regional resources (the landing bucket)."
  type        = string
  default     = "us-central1"
}

variable "bq_location" {
  description = "BigQuery location. Must match JIRA_BQ_LOCATION in the Composer environment's variables (an OS env var read at DAG parse time, not an Airflow Variable)."
  type        = string
  default     = "US"
}

variable "env" {
  description = "Environment name, used in resource labels."
  type        = string
  default     = "dev"
}

variable "landing_bucket_name" {
  description = <<-EOT
    GCS bucket holding the daily Jira exports at jira_exports/dt=YYYY-MM-DD/.
    This bucket -- not the raw dataset -- is the durable archive of source data,
    so its retention window bounds how far back the pipeline can be reprocessed.
  EOT
  type        = string
}

variable "landing_retention_days" {
  description = "Days to keep daily export files before deletion. Bounds the reprocessing window."
  type        = number
  default     = 365
}

variable "landing_nearline_after_days" {
  description = "Age at which export files move to NEARLINE storage. Set to 0 to disable."
  type        = number
  default     = 30
}

variable "stage_partition_expiration_days" {
  description = <<-EOT
    Retention for stage.jira_issues partitions. stage holds the full daily
    snapshot history, so this is the main storage cost lever at production
    scale. null keeps partitions indefinitely.
  EOT
  type        = number
  default     = null
}

variable "dq_partition_expiration_days" {
  description = "Retention for dq.dq_findings partitions."
  type        = number
  default     = 365
}

variable "deletion_protection" {
  description = <<-EOT
    Blocks `terraform destroy` and any provider-initiated table replacement.
    Keep true outside throwaway environments: it is what turns an incompatible
    schema change into a failed apply rather than a dropped table.
  EOT
  type        = bool
  default     = true
}

variable "pipeline_service_account" {
  description = <<-EOT
    Email of the service account the Composer workers run as. When set, it is
    granted read on the landing bucket, dataEditor on the four datasets, and
    jobUser on the project. Composer itself is managed elsewhere; only the
    grants this pipeline depends on are declared here.
    Leave null to manage these bindings outside Terraform.
  EOT
  type        = string
  default     = null
}

variable "labels" {
  description = "Extra labels applied to every dataset and bucket."
  type        = map(string)
  default     = {}
}

locals {
  common_labels = merge(
    {
      env      = var.env
      pipeline = "jira-daily"
      managed  = "terraform"
    },
    var.labels,
  )
}
