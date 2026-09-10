"""Jira -> BigQuery daily ELT.

Tables and schemas are Terraform-managed; every job here uses CREATE_NEVER.
Params: project_id, landing_bucket, dt, full_load. See etl/README.md.
"""
from __future__ import annotations

import os

import pendulum
from airflow.decorators import dag
from airflow.models.param import Param
from airflow.providers.google.cloud.operators.bigquery import BigQueryInsertJobOperator
from airflow.providers.google.cloud.sensors.gcs import GCSObjectsWithPrefixExistenceSensor

# Lets the SQL resolve as "sql/xxx.sql" wherever the dags folder is synced to.
DAG_FOLDER = os.path.dirname(os.path.abspath(__file__))

# Parse-time: `location` is not a templated field.
BQ_LOCATION = os.environ.get("JIRA_BQ_LOCATION", "US")

# os.environ, not Variable.get -- the latter hits the metadata DB every parse.
DEFAULT_PROJECT_ID = os.environ.get("JIRA_PROJECT_ID", "jira-case-study")
DEFAULT_LANDING_BUCKET = os.environ.get("JIRA_LANDING_BUCKET", "datalake-lan-dev")

# data_interval_end, not ds: ds is the START of the interval, i.e. the day before.
_DATE = "params.dt or (data_interval_end | ds)"

EFFECTIVE_DATE = "{{ " + _DATE + " }}"
EFFECTIVE_DATE_NODASH = "{{ (" + _DATE + ") | replace('-', '') }}"

# Always the partition decorator: a table-level WRITE_TRUNCATE would overwrite
# the Terraform-managed schema. Wiping other partitions is 00's job.
STAGE_TABLE_ID = "jira_issues${{ (" + _DATE + ") | replace('-', '') }}"

EXPORT_PREFIX = f"jira_exports/dt={EFFECTIVE_DATE}/"
SOURCE_URI = "gs://{{ params.landing_bucket }}/" + EXPORT_PREFIX + "*.json"


class BigQueryLoadJobOperator(BigQueryInsertJobOperator):
    """`BigQueryInsertJobOperator` minus template-file resolution.

    The base class loads templated strings ending `.json`/`.sql` from
    `template_searchpath`, which would make the `*.json` sourceUri below raise
    `TemplateNotFound`.
    """

    template_ext = ()


DT_QUERY_PARAM = [
    {
        "name": "dt",
        "parameterType": {"type": "DATE"},
        "parameterValue": {"value": EFFECTIVE_DATE},
    }
]

# run_id scopes DQ rows to one attempt, so a retry replaces only its own.
DQ_QUERY_PARAMS = DT_QUERY_PARAM + [
    {
        "name": "run_id",
        "parameterType": {"type": "STRING"},
        "parameterValue": {"value": "{{ run_id }}"},
    }
]


@dag(
    dag_id="jira_daily_load",
    # An hour after the export is expected to land.
    schedule="0 1 * * *",
    start_date=pendulum.datetime(2026, 1, 1, tz="UTC"),
    # Off: would queue hundreds of runs. Backfill via the `dt` Param instead.
    catchup=False,
    max_active_runs=1,
    dagrun_timeout=pendulum.duration(hours=3),
    default_args={
        "retries": 2,
        "retry_delay": pendulum.duration(minutes=5),
    },
    template_searchpath=[DAG_FOLDER],
    params={
        "project_id": Param(DEFAULT_PROJECT_ID, type="string"),
        "landing_bucket": Param(DEFAULT_LANDING_BUCKET, type="string"),
        "dt": Param(None, type=["null", "string"], format="date"),
        "full_load": Param(False, type="boolean"),
    },
    tags=["jira", "bigquery", "elt"],
)
def jira_bq_pipeline():

    # Without this a missing export surfaces later as "stage partition empty",
    # which points at the wrong layer.
    wait_for_export = GCSObjectsWithPrefixExistenceSensor(
        task_id="wait_for_export",
        bucket="{{ params.landing_bucket }}",
        prefix=EXPORT_PREFIX,
        mode="reschedule",
        poke_interval=300,
        timeout=60 * 60 * 6,
    )

    # No `schema` in the load config: the deployed Terraform schema is used.
    #
    # WRITE_TRUNCATE: raw holds the latest snapshot only, which is why
    # 01_stage_load.sql can read it with no WHERE clause.
    raw_load = BigQueryLoadJobOperator(
        task_id="raw_load",
        location=BQ_LOCATION,
        configuration={
            "load": {
                "sourceUris": [SOURCE_URI],
                "sourceFormat": "NEWLINE_DELIMITED_JSON",
                "destinationTable": {
                    "projectId": "{{ params.project_id }}",
                    "datasetId": "raw",
                    "tableId": "jira_issues",
                },
                "writeDisposition": "WRITE_TRUNCATE",
                "createDisposition": "CREATE_NEVER",
                # Drops top-level keys outside the schema; GCS keeps the original.
                "ignoreUnknownValues": True,
                # Fail rather than silently drop a malformed row.
                "maxBadRecords": 0,
            }
        },
    )

    # Renders to `SELECT 1` unless full_load=true.
    truncate_stage = BigQueryInsertJobOperator(
        task_id="truncate_stage",
        location=BQ_LOCATION,
        configuration={
            "query": {
                "query": "sql/00_truncate_stage.sql",
                "useLegacySql": False,
            }
        },
    )

    # WRITE_TRUNCATE + partition decorator: reruns for the same @dt are
    # idempotent and leave other partitions alone.
    stage_load = BigQueryInsertJobOperator(
        task_id="stage_load",
        location=BQ_LOCATION,
        configuration={
            "query": {
                "query": "sql/01_stage_load.sql",
                "useLegacySql": False,
                "queryParameters": DT_QUERY_PARAM,
                "destinationTable": {
                    "projectId": "{{ params.project_id }}",
                    "datasetId": "stage",
                    "tableId": STAGE_TABLE_ID,
                },
                "writeDisposition": "WRITE_TRUNCATE",
                "createDisposition": "CREATE_NEVER",
            }
        },
    )

    # Raises on any HIGH violation, stopping the merge. Findings are written
    # first, so a failed run still explains itself.
    dq_stage = BigQueryInsertJobOperator(
        task_id="dq_stage",
        location=BQ_LOCATION,
        configuration={
            "query": {
                "query": "sql/02_dq_stage.sql",
                "useLegacySql": False,
                "queryParameters": DQ_QUERY_PARAMS,
            }
        },
    )

    merge_core = BigQueryInsertJobOperator(
        task_id="merge_core",
        location=BQ_LOCATION,
        configuration={
            "query": {
                "query": "sql/03_merge_core.sql",
                "useLegacySql": False,
                "queryParameters": DT_QUERY_PARAM,
            }
        },
    )

    # Core invariants, plus the metrics only measurable after the merge.
    dq_core = BigQueryInsertJobOperator(
        task_id="dq_core",
        location=BQ_LOCATION,
        configuration={
            "query": {
                "query": "sql/04_dq_core.sql",
                "useLegacySql": False,
                "queryParameters": DQ_QUERY_PARAMS,
            }
        },
    )

    (
        wait_for_export
        >> raw_load
        >> truncate_stage
        >> stage_load
        >> dq_stage
        >> merge_core
        >> dq_core
    )


jira_bq_pipeline()
