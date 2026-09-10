# Retention model & schema evolution

Detail behind [README.md](README.md). Overview: [README.md](../../README.md).

## Retention model

| Layer | Holds | Partitioned |
|---|---|---|
| `gs://<landing>/jira_exports/dt=…` | every daily export, verbatim | by prefix |
| `raw.jira_issues` | the **latest snapshot only** (`WRITE_TRUNCATE`) | no |
| `stage.jira_issues` | **full snapshot history** | by `dt` |
| `core.jira_issues` | one row per issue, latest state | no — see below |

**The landing bucket, not the raw dataset, is the durable archive.**
`landing_retention_days` therefore sets how far back the pipeline can be
replayed. Reprocessing an old date means pointing `raw_load` at that day's GCS
prefix and re-running; `stage` writes to that date's partition and the MERGE is
idempotent.

Because `raw` holds only the current snapshot, `01_stage_load.sql` reads it
with no `WHERE` clause. If `raw` ever becomes append-across-runs, that query
needs a batch filter or every run will reprocess all of history into one
partition.

**Two columns record time.** `dt` (stage) and `date` (core) are the export's
*arrival* date, which a backfill rewrites to an older value. `etl_ts` is when
the row was actually written and is never rewritten. Use `dt`/`date` to ask
which export a row came from, `etl_ts` to ask when the pipeline ran.

**`full_load=true`** truncates every stage partition and rebuilds it from the
current snapshot, discarding the snapshot history — after which replaying an
older date means re-reading its export from GCS. `core` is untouched: the SCD1
merge only upserts, so it keeps every row it already had.

## Rebuilding `core`

`core` is derived, not authoritative — every row in it is reconstructable from
`stage`. Dropping and rebuilding it, or deriving an SCD2 history table
alongside it, is a query over the snapshot partitions, not a re-ingestion.

The limit is snapshot granularity: history is only as fine as the export
schedule, so a change that was overwritten before the next export was taken is
not recoverable. `fields.updated` gives finer ordering where an export happens
to carry several versions of one issue, but that coverage is incidental, not
guaranteed.

`full_load=true` discards this capability along with the history. The GCS
archive is the deeper backstop — any export inside `landing_retention_days`
can be re-loaded.

## Why `core` is not partitioned

`core` is SCD1 — one row per issue — so it grows with the number of tickets,
not with time. At ~420 bytes/row (measured from the sample export):

| issues | `core` size |
|---|---|
| 100k | 0.04 GB |
| 1M | 0.42 GB |
| 5M (very large instance) | 2.1 GB |

Daily partitions on a table that size would mean thousands of partitions well
under a megabyte each. BigQuery handles that *worse* than no partitioning:
below roughly 1 GB a partition costs metadata overhead without buying useful
pruning.

Partitioning also would not help the workload that touches `core` most. The
daily MERGE matches every incoming id against the whole table, and an update
can land on a ticket of any age, so there is no partition filter to prune on.

Clustering is the right tool here — it needs no fixed boundaries — with **`id`**
leading, because BigQuery clusters hierarchically and only the leading column
prunes reliably. The MERGE joins on `id`, so `id` is what has to lead.

`project` follows. `id` is unique under SCD1, so the sort order is unchanged and
`project` adds only block min/max metadata — free, but not something to rely on
for project-filtered queries. It starts mattering if `core` stops being SCD1.

The "millions to billions" case is real, but it lands in `stage`, not `core`:
a daily full snapshot of a 1M-issue instance is ~0.36B rows/year, and `stage`
is partitioned by `dt`.

Revisit only if `core` stops being SCD1. An SCD2 history table would grow with
changes rather than tickets and would want partitioning by validity date.

## Schema evolution

The schema JSON is the declared state; drift shows up in `terraform plan`.

### Patched in place

Adding a column, dropping a column, or relaxing `REQUIRED` → `NULLABLE`. Edit
the JSON, open a PR, apply.

Most new Jira fields need **no schema change at all** — `raw` and `stage` carry
the payload in a single `fields JSON` column, so a new custom field is
queryable immediately. Only promoting it to a typed column in `core` touches
the schema, which means editing three places:

1. `schemas/core_jira_issues.json`
2. `03_merge_core.sql` — the `parsed` CTE
3. `03_merge_core.sql` — the `UPDATE SET` and `INSERT`/`VALUES` lists

The MERGE names every column explicitly, so a mismatch is rejected rather than
silently shifting data across columns. What that cannot catch is a column added
to the schema but forgotten in the MERGE — it just stays NULL forever. A
`bq query --dry_run` gate in CI is the intended defence.

### Forces replacement

Renaming a column, changing a type, or tightening `NULLABLE` → `REQUIRED`. The
plan shows `must be replaced` and `] # forces replacement`, meaning the table
is destroyed and rebuilt empty.

**Changing `clustering` may land here** depending on the provider version.
BigQuery supports altering it in place; the provider has not always exposed
that. Read the plan — if it says replace, apply out of band and let Terraform
reconcile:

```bash
bq update --clustering_fields=id,project <project>:core.jira_issues
```

`deletion_protection = true` turns that into a failed apply instead of lost
data. It is **off** in `envs/dev.tfvars`, where nothing stops it — read the
plan before confirming.

A rename is the trap: harmless-looking in a diff, destructive in effect. Do it
as add-new → backfill → drop-old and you stay in place throughout. For larger
changes, build a new table, backfill, `terraform state mv`, retire the old one.
Never resolve a destructive diff by turning `deletion_protection` off on a
table holding data.

### Drift check

```bash
terraform plan -var-file=envs/prod.tfvars -detailed-exitcode
```

Exit `0` = no drift, `2` = deployed schema no longer matches the config.
