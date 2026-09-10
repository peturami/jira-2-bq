project_id          = "jira-case-study"
region              = "us-central1"
bq_location         = "US"
env                 = "dev"
landing_bucket_name = "datalake-lan-dev"

# Short archive + short stage history keeps the dev footprint small.
landing_retention_days          = 30
landing_nearline_after_days     = 0
stage_partition_expiration_days = 30
dq_partition_expiration_days    = 30

# Dev is meant to be torn down and rebuilt; production is not.
deletion_protection = false

# pipeline_service_account = "composer-worker@jira-case-study .iam.gserviceaccount.com"
