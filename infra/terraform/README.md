# Infrastructure

Terraform owns every BigQuery dataset and table, plus the GCS landing bucket.
There is no `CREATE TABLE` in the ETL code and every BigQuery job runs with
`createDisposition: CREATE_NEVER` — so a table Terraform does not know about
cannot come into existence.

**Composer is assumed to be owned by a central infrastructure repo**, so it is
not created here. This configuration stops at what the pipeline needs — the
four datasets, five tables and the landing bucket — plus the IAM grants its
Composer worker service account depends on, declared so a missing grant shows
up as a Terraform diff rather than a 403 at 3am.

Deploying a DAG change therefore never requires `terraform apply`; it is a
bucket sync, see [scripts/](../../scripts/README.md).

## Layout

```
versions.tf     provider pin, GCS backend
variables.tf    inputs + common labels
datasets.tf     raw / stage / core / dq
tables.tf       the five tables, partitioning and clustering
storage.tf      landing bucket + lifecycle rules
iam.tf          grants for the Composer worker service account
schemas/        BigQuery schema JSON, one file per table
envs/           per-environment tfvars
```

Schemas are external JSON, not inline HCL: it is BigQuery's own format, so it
round-trips with `bq show --schema` and a column change reads as a small diff.

## Deploying

```bash
terraform init -backend-config="bucket=<tf-state-bucket>"
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

The state bucket is a bootstrap dependency and is deliberately not managed
here — Terraform cannot create the bucket holding its own state.

`bq_location` must match **`JIRA_BQ_LOCATION`** in the Composer environment's
variables — an OS env var read at DAG parse time, not an Airflow Variable:

```bash
gcloud composer environments update <env> --location <region> \
  --update-env-variables=JIRA_BQ_LOCATION=<location>
```

Unset, it defaults to `US`. BigQuery will not run a job across locations and
the error is not obvious.

## Changing a schema

Adding or dropping a column is patched **in place**. Renaming a column,
changing a type, or tightening `NULLABLE` → `REQUIRED` **destroys and
recreates the table** — `deletion_protection` is the only brake, and it is off
in `dev`. Always read the plan before confirming.

Terraform and the DAG deploy are one deployment: a schema change that lands in
only one of them breaks the next run.

→ [Retention model & schema evolution](RETENTION_AND_EVOLUTION.md)
