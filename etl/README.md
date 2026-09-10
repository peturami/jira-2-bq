# ETL

One Airflow DAG (`jira_daily_load`) and five SQL scripts. The DAG holds no
transformation logic — it orders the SQL, passes it `@dt` and `@run_id`, and
lets a failing script stop the run.

```
airflow/dags/
  jira_daily_load_dag.py
  sql/                     numbered in execution order
```

## Tasks

| Task | Does |
|---|---|
| `wait_for_export` | sensor on `jira_exports/dt=…/`, `reschedule` mode, 6h timeout |
| `raw_load` | GCS → `raw`, `WRITE_TRUNCATE`, `max_bad_records=0` |
| `truncate_stage` | `00_truncate_stage.sql` — no-op unless `full_load=true` |
| `stage_load` | `01_stage_load.sql` → the day's `stage` partition |
| `dq_stage` | `02_dq_stage.sql` — 12 rules, HIGH stops the run |
| `merge_core` | `03_merge_core.sql` — SCD1 merge |
| `dq_core` | `04_dq_core.sql` — 1 rule + post-merge metrics |

`raw_load` declares **no schema**: the table is Terraform-managed and
`CREATE_NEVER` guarantees it exists, so the load inherits the deployed schema.
Omitting `schema` from a `load` config is how the API says that. Hence
`BigQueryInsertJobOperator`, not `GCSToBigQueryOperator` — the latter's only
equivalent is `autodetect=None`, which works solely because it branches on
`is False` on a parameter typed `bool`.

`BigQueryLoadJobOperator` is a four-line subclass clearing `template_ext`, which
would otherwise resolve the `*.json` sourceUri as a template file.

## Params

| Param | Purpose |
|---|---|
| `project_id` | GCP project (default from `JIRA_PROJECT_ID`) |
| `landing_bucket` | export bucket (default from `JIRA_LANDING_BUCKET`) |
| `dt` | process a specific date instead of the scheduled one |
| `full_load` | wipe `stage` and rebuild from the current snapshot |

Environment-specific values are Params, so they render through Jinja at
runtime and can be overridden per run. Defaults come from environment
variables on the Composer environment — never `Variable.get()` at module
scope, which hits the metadata DB on every DAG parse. `BQ_LOCATION` is the
exception: `location` is not a templated field, so it resolves at parse time.

## The run date

```python
EFFECTIVE_DATE = "{{ params.dt or (data_interval_end | ds) }}"
```

`dt=X` in the bucket is the date the export was *uploaded*, and it lands just
after midnight UTC, so the 01:00 run must process X. That is
`data_interval_end`, **not** `ds` — for a daily schedule `ds` is the *start* of
the interval and would silently process X-1 on Airflow 2.

`catchup=False`; backfill a specific day with the `dt` Param instead. Every
step is idempotent for a given `dt`: `stage_load` truncates that partition
alone via the partition decorator, and the MERGE is an upsert.

## Data quality

Both DQ scripts follow the same order: **evaluate every rule → write the
violations → then fail**. `ASSERT` would abort where it fires, losing the
record and reporting only the first broken rule; instead the scripts raise with
`ERROR(FORMAT(...))` listing every violation at once.

`severity=HIGH` fails the run. `MEDIUM` and `LOW` are recorded only. Only
violations reach `dq.dq_findings` — a clean run writes nothing there, so any
row in that table is a problem. `dq.dq_metrics` is written every run and is
what shows a run happened at all.

## Deploying

The SQL is resolved via `template_searchpath`, so `dags/sql/` must sit beside
the DAG in the Composer bucket — see [scripts/](../scripts/README.md).
Terraform and the DAG deploy are one deployment:
[infra/terraform/](../infra/terraform/README.md).
