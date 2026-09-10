-- DQ: core layer (post-merge). Same shape as 02_dq_stage.sql.
-- Only invariants 02 cannot check: a failure here is already in core.

CREATE TEMP TABLE _agg AS
SELECT
  -- Global invariant, so whole-table -- but it reads one column.
  (SELECT COUNT(*) - COUNT(DISTINCT id)
   FROM `{{ params.project_id }}.core.jira_issues`) AS id_dupe_n,

  (SELECT COUNT(*) FROM `{{ params.project_id }}.core.jira_issues`) AS core_rows_after,

  (SELECT COUNT(*)
   FROM `{{ params.project_id }}.core.jira_issues`
   WHERE date = @dt) AS core_rows_touched,

  -- NUMERIC divide keeps the rate exact.
  (SELECT SAFE_DIVIDE(CAST(COUNTIF(customer_request_type IS NULL) AS NUMERIC), COUNT(*))
   FROM `{{ params.project_id }}.core.jira_issues`
   WHERE date = @dt) AS request_type_null_rate,

  (SELECT MAX(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E3S%z', updated))
   FROM `{{ params.project_id }}.core.jira_issues`
   WHERE date = @dt) AS max_updated_ts,

  -- Written by 02 earlier in this run; splits inserted from updated below.
  (SELECT metric_value
   FROM `{{ params.project_id }}.dq.dq_metrics`
   WHERE run_date = @dt AND dag_run_id = @run_id
     AND layer = 'core' AND metric_name = 'row_count_before') AS core_rows_before;

DELETE FROM `{{ params.project_id }}.dq.dq_metrics`
WHERE run_date = @dt AND dag_run_id = @run_id
  AND layer = 'core'
  AND metric_name IN ('row_count_after', 'rows_inserted', 'rows_updated',
                      'request_type_null_rate', 'max_updated_epoch_seconds');

DELETE FROM `{{ params.project_id }}.dq.dq_findings`
WHERE run_date = @dt AND dag_run_id = @run_id AND layer = 'core';

-- inserted = table growth; updated = everything else the merge touched.
-- Rows examined but left alone count as neither.
-- ------------------------------------------------------------
INSERT INTO `{{ params.project_id }}.dq.dq_metrics`
  (run_date, dag_run_id, layer, metric_name, metric_value, etl_ts)

SELECT @dt, @run_id, 'core', 'row_count_after',
       CAST(core_rows_after AS NUMERIC), CURRENT_TIMESTAMP() FROM _agg
UNION ALL
SELECT @dt, @run_id, 'core', 'rows_inserted',
       CAST(core_rows_after AS NUMERIC) - core_rows_before, CURRENT_TIMESTAMP() FROM _agg
UNION ALL
SELECT @dt, @run_id, 'core', 'rows_updated',
       CAST(core_rows_touched AS NUMERIC) - (CAST(core_rows_after AS NUMERIC) - core_rows_before),
       CURRENT_TIMESTAMP() FROM _agg
UNION ALL
SELECT @dt, @run_id, 'core', 'request_type_null_rate',
       request_type_null_rate, CURRENT_TIMESTAMP() FROM _agg
UNION ALL
-- Epoch, not lag: lag moves when a retry measures later, tracking scheduling
-- rather than freshness. Recover it with TIMESTAMP_DIFF against etl_ts.
SELECT @dt, @run_id, 'core', 'max_updated_epoch_seconds',
       CAST(UNIX_SECONDS(max_updated_ts) AS NUMERIC), CURRENT_TIMESTAMP() FROM _agg
;

-- Findings: violations only.
-- ------------------------------------------------------------
INSERT INTO `{{ params.project_id }}.dq.dq_findings`
  (run_date, dag_run_id, layer, check_name, severity,
   rows_affected, observed_value, sample, message, etl_ts)

SELECT @dt, @run_id, 'core', 'id_unique', 'HIGH',
       id_dupe_n, CAST(NULL AS FLOAT64), CAST(NULL AS STRING),
       'id must be unique across core.jira_issues (SCD1 invariant).',
       CURRENT_TIMESTAMP()
FROM _agg WHERE id_dupe_n > 0
;

-- Gate.
-- ------------------------------------------------------------
SELECT IF(
  failed_n > 0,
  ERROR(FORMAT('DQ HIGH (core, dt=%t): %d rule(s) violated -> %s',
               @dt, failed_n, failed_rules)),
  'core DQ passed'
)
FROM (
  SELECT
    COUNT(*) AS failed_n,
    STRING_AGG(FORMAT('%s (%d rows)', check_name, rows_affected), '; '
               ORDER BY check_name) AS failed_rules
  FROM `{{ params.project_id }}.dq.dq_findings`
  WHERE run_date = @dt AND dag_run_id = @run_id
    AND layer = 'core' AND severity = 'HIGH'
);
