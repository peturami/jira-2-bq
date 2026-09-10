# Jira → BigQuery pipeline — design

Daily Jira exports land in GCS as newline-delimited JSON. Airflow loads them
through three BigQuery layers into one curated, query-ready table, gating each
step on data quality. Schemas and tables are owned by Terraform; the DAG never
creates anything.

## Flow

```
gs://<landing>/jira_exports/dt=YYYY-MM-DD/*.json
        |
        |  wait_for_export      sensor, waits for the day's export
        v
  raw.jira_issues               WRITE_TRUNCATE - latest snapshot only
        |
        |  truncate_stage       no-op unless full_load=true
        |  stage_load           dedup #1: byte-identical rows
        v
  stage.jira_issues             partitioned by dt - full snapshot history
        |
        |  dq_stage  ---------> dq.dq_metrics    (always)
        |                       dq.dq_findings   (violations only)  --HIGH--> stop
        |  merge_core           dedup #2: older versions of the same id
        v
  core.jira_issues              SCD1 - one row per issue, latest state
        |
        |  dq_core   ---------> dq.dq_metrics / dq.dq_findings      --HIGH--> stop
        v
     consumers
```

DAG `jira_daily_load`, `schedule="0 1 * * *"`, `max_active_runs=1`.

## Layers

| Dataset | Holds | Partitioned |
|---|---|---|
| GCS bucket | every export, verbatim — **the durable archive** | by prefix |
| `raw` | latest snapshot only | no |
| `stage` | full snapshot history, typed + deduped | by `dt` |
| `core` | one row per issue id, latest state | no — [by design](infra/terraform/RETENTION_AND_EVOLUTION.md#why-core-is-not-partitioned) |
| `dq` | metrics (every run) + findings (violations only) | by `run_date` |

## Key decisions

- **GCS, not `raw`, is the archive.** `raw` is truncated every run, so the
  bucket's retention window is the replay window.
- **Two timestamps.** `dt`/`date` is the export's arrival date and a backfill
  rewrites it; `etl_ts` is when the row was actually written and never moves.
- **`data_interval_end`, not `ds`.** The export for day X lands just after
  midnight on day X, so the 01:00 run must process X. `ds` would give X-1.
- **DQ evaluates, logs, then gates.** `ASSERT` aborts where it fires, so
  violations are written first and a single error reports all of them.
  `severity=HIGH` fails the run; `MEDIUM`/`LOW` are recorded only.
- **`core` is derivable.** `stage` keeps every snapshot, so `core` can be
  dropped and rebuilt — or an SCD2 table derived — without re-ingesting.
- **Composer is out of scope.** The Airflow environment is assumed to be owned
  by a central infrastructure repo, so this Terraform creates the datasets,
  tables and landing bucket — not Composer itself. Deploying here means syncing
  the DAG to that environment's bucket.
- **Terraform owns all schemas.** Every BigQuery job uses `CREATE_NEVER`, so a
  table the IaC doesn't know about cannot exist.

## Repo map

```
etl/airflow/dags/     DAG + SQL, numbered in execution order (00..04)
infra/terraform/      datasets, tables, schemas/*.json, landing bucket
scripts/              deploy_dags.sh - syncs DAG + SQL to Composer
```

Terraform and the DAG deploy are **one deployment** — a schema change that
lands in only one of them breaks the run.

## Detailed docs

- [Infrastructure](infra/terraform/README.md) — datasets, tables, deploying
  - [Retention model & schema evolution](infra/terraform/RETENTION_AND_EVOLUTION.md)
- [ETL](etl/README.md) — the DAG, its params, and the SQL
- [Scripts](scripts/README.md) — deploying the DAG and SQL to Composer
