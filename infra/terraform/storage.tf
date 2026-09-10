# Daily exports at jira_exports/dt=YYYY-MM-DD/. This, not raw.jira_issues, is
# the durable archive -- landing_retention_days is the replay window.
resource "google_storage_bucket" "landing" {
  name     = var.landing_bucket_name
  project  = var.project_id
  location = var.region
  labels   = local.common_labels

  # Make an accidental destroy fail rather than take the archive with it.
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  storage_class = "STANDARD"

  # Guards a good export against a corrupted re-upload.
  versioning {
    enabled = true
  }

  dynamic "lifecycle_rule" {
    for_each = var.landing_nearline_after_days > 0 ? [1] : []
    content {
      condition {
        age = var.landing_nearline_after_days
      }
      action {
        type          = "SetStorageClass"
        storage_class = "NEARLINE"
      }
    }
  }

  lifecycle_rule {
    condition {
      age = var.landing_retention_days
    }
    action {
      type = "Delete"
    }
  }

  # Drop superseded versions so versioning does not double the bill.
  lifecycle_rule {
    condition {
      age                = 7
      with_state         = "ARCHIVED"
      num_newer_versions = 1
    }
    action {
      type = "Delete"
    }
  }
}
