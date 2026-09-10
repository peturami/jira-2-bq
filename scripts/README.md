# Scripts

## `deploy_dags.sh`

Syncs the DAG and its SQL to the Composer environment's GCS bucket. That is
the whole deployment — Airflow picks up the bucket on its own, with a delay of
a minute or two.

```bash
./scripts/deploy_dags.sh              # uses COMPOSER_BUCKET set in the script
./scripts/deploy_dags.sh other-bucket # argument overrides it
./scripts/deploy_dags.sh --dry-run    # show what would change
```

The bucket is a constant at the top of the file, not something looked up. Find
it once with:

```bash
gcloud composer environments describe <env> --location <region> \
  --format="value(config.dagGcsPrefix)"
```

It is the Composer environment's own bucket — **not** the data landing bucket.

### How it syncs

```
etl/airflow/dags/<dag>.py  --copy-->  gs://<bucket>/dags/<dag>.py
etl/airflow/dags/sql/      --sync-->  gs://<bucket>/dags/sql/
```

The asymmetry is deliberate. `dags/` also holds Composer's own
`airflow_monitoring.py`, which a delete-sync would fight over, so the DAG is
copied. `dags/sql/` is wholly ours, so it is mirrored exactly — which is what
makes a deleted `.sql` file actually disappear.

Afterwards the script verifies the DAG object exists and that the `.sql` count
matches local, because an upload that writes nothing can still exit 0.

### Deploying alongside Terraform

A schema change is **one deployment in two halves**. Widening changes (a new
nullable column) tolerate Terraform going first; retyping does not, so deploy
both back to back and expect the run in between to fail.

See [infra/terraform/](../infra/terraform/README.md).
