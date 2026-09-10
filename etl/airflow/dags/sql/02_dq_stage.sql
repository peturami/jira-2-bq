-- DQ: stage layer (pre-merge). Evaluate every rule, write the violations,
-- then raise if any HIGH one fired -- ASSERT would abort before logging and
-- stops at the first failure. Only violations are written; see etl/README.md.

-- One scan: every rule is a COUNTIF, plus 5 sample keys per violation.
CREATE TEMP TABLE _agg AS
WITH raw_rows AS (
  SELECT
    id,
    key,
    fields,
    COALESCE(key, CONCAT('id:', IFNULL(id, 'null')))        AS row_ref,
    SPLIT(key, '-')[SAFE_OFFSET(0)]                         AS derived_project,
    JSON_VALUE(fields, '$.project.key')                     AS payload_project_key,
    JSON_VALUE(fields, '$.status.name')                     AS status_name,
    JSON_VALUE(fields, '$.resolution.name')                 AS resolution_name,
    JSON_VALUE(fields, '$.customfield_10002.errorMessage')  AS request_type_error,
    SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E3S%z', JSON_VALUE(fields, '$.updated'))        AS updated_ts,
    SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E3S%z', JSON_VALUE(fields, '$.created'))        AS created_ts,
    SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E3S%z', JSON_VALUE(fields, '$.resolutiondate')) AS resolved_ts
  FROM `{{ params.project_id }}.stage.jira_issues`
  WHERE dt = @dt
)
SELECT
  COUNT(*)                AS stage_rows,
  COUNT(DISTINCT id)      AS stage_distinct_ids,
  COUNTIF(id IS NULL OR id = '') AS id_not_null_n,
  TO_JSON_STRING(ARRAY_AGG(IF(id IS NULL OR id = '',
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS id_not_null_s,
  COUNTIF(key IS NULL OR key = '') AS key_not_null_n,
  TO_JSON_STRING(ARRAY_AGG(IF(key IS NULL OR key = '',
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS key_not_null_s,
  COUNTIF(key IS NOT NULL AND key != ''
          AND NOT REGEXP_CONTAINS(key, r'^[A-Z][A-Z0-9_]+-[0-9]+$')) AS key_format_n,
  TO_JSON_STRING(ARRAY_AGG(IF(key IS NOT NULL AND key != ''
          AND NOT REGEXP_CONTAINS(key, r'^[A-Z][A-Z0-9_]+-[0-9]+$'),
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS key_format_s,
  COUNTIF(id IS NOT NULL AND id != '' AND SAFE_CAST(id AS INT64) IS NULL) AS id_is_integer_n,
  TO_JSON_STRING(ARRAY_AGG(IF(id IS NOT NULL AND id != '' AND SAFE_CAST(id AS INT64) IS NULL,
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS id_is_integer_s,
  COUNTIF(updated_ts IS NULL) AS updated_parseable_n,
  TO_JSON_STRING(ARRAY_AGG(IF(updated_ts IS NULL,
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS updated_parseable_s,
  COUNTIF(fields IS NULL OR TO_JSON_STRING(fields) IN ('{}', 'null')) AS payload_not_empty_n,
  TO_JSON_STRING(ARRAY_AGG(IF(fields IS NULL OR TO_JSON_STRING(fields) IN ('{}', 'null'),
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS payload_not_empty_s,
  COUNTIF(derived_project IS NOT NULL AND payload_project_key IS NOT NULL
           AND derived_project != payload_project_key) AS project_key_matches_n,
  TO_JSON_STRING(ARRAY_AGG(IF(derived_project IS NOT NULL AND payload_project_key IS NOT NULL
           AND derived_project != payload_project_key,
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS project_key_matches_s,
  COUNTIF(resolved_ts IS NOT NULL AND created_ts IS NOT NULL AND resolved_ts < created_ts) AS resolved_after_created_n,
  TO_JSON_STRING(ARRAY_AGG(IF(resolved_ts IS NOT NULL AND created_ts IS NOT NULL AND resolved_ts < created_ts,
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS resolved_after_created_s,
  COUNTIF(created_ts > CURRENT_TIMESTAMP()) AS created_not_in_future_n,
  TO_JSON_STRING(ARRAY_AGG(IF(created_ts > CURRENT_TIMESTAMP(),
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS created_not_in_future_s,
  COUNTIF(status_name IN ('Done', 'Closed', 'Resolved') AND resolution_name IS NULL) AS done_has_resolution_n,
  TO_JSON_STRING(ARRAY_AGG(IF(status_name IN ('Done', 'Closed', 'Resolved') AND resolution_name IS NULL,
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS done_has_resolution_s,
  COUNTIF(request_type_error IS NOT NULL) AS request_type_no_error_stub_n,
  TO_JSON_STRING(ARRAY_AGG(IF(request_type_error IS NOT NULL,
    row_ref, NULL) IGNORE NULLS LIMIT 5)) AS request_type_no_error_stub_s
FROM raw_rows;

-- Unfiltered COUNT(*) is answered from metadata, so this is free.
CREATE TEMP TABLE _ctx AS
SELECT
  (SELECT COUNT(*) FROM `{{ params.project_id }}.raw.jira_issues`)   AS raw_rows,
  (SELECT COUNT(*) FROM `{{ params.project_id }}.core.jira_issues`)  AS core_rows_before;

-- Per-attempt idempotency: a retry replaces only its own rows.
DELETE FROM `{{ params.project_id }}.dq.dq_metrics`
WHERE run_date = @dt AND dag_run_id = @run_id
  AND ((layer = 'raw'   AND metric_name = 'row_count')
    OR (layer = 'core'  AND metric_name = 'row_count_before')
    OR (layer = 'stage' AND metric_name IN ('row_count', 'distinct_ids',
                                            'dedup_dropped', 'merge_dedup_expected')));

DELETE FROM `{{ params.project_id }}.dq.dq_findings`
WHERE run_date = @dt AND dag_run_id = @run_id AND layer = 'stage';

-- dedup_dropped: byte-identical rows collapsed at stage load (upstream
-- redundancy). merge_dedup_expected: older versions the merge will collapse
-- (SCD1 working as intended).
--
-- NULLs are CAST because a bare NULL is INT64 in BigQuery and every branch
-- here supplies NULL for the same column. Do not simplify them away.
-- ------------------------------------------------------------
INSERT INTO `{{ params.project_id }}.dq.dq_metrics`
  (run_date, dag_run_id, layer, metric_name, metric_value, etl_ts)

SELECT @dt, @run_id, 'raw',   'row_count',        CAST(raw_rows AS NUMERIC),          CURRENT_TIMESTAMP() FROM _ctx
UNION ALL
SELECT @dt, @run_id, 'core',  'row_count_before', CAST(core_rows_before AS NUMERIC),  CURRENT_TIMESTAMP() FROM _ctx
UNION ALL
SELECT @dt, @run_id, 'stage', 'row_count',        CAST(stage_rows AS NUMERIC),        CURRENT_TIMESTAMP() FROM _agg
UNION ALL
SELECT @dt, @run_id, 'stage', 'distinct_ids',     CAST(stage_distinct_ids AS NUMERIC), CURRENT_TIMESTAMP() FROM _agg
UNION ALL
SELECT @dt, @run_id, 'stage', 'dedup_dropped',
       CAST((SELECT raw_rows FROM _ctx) - stage_rows AS NUMERIC), CURRENT_TIMESTAMP() FROM _agg
UNION ALL
SELECT @dt, @run_id, 'stage', 'merge_dedup_expected',
       CAST(stage_rows - stage_distinct_ids AS NUMERIC), CURRENT_TIMESTAMP() FROM _agg
;

-- Findings: violations only -- a clean run writes nothing here.
-- ------------------------------------------------------------
INSERT INTO `{{ params.project_id }}.dq.dq_findings`
  (run_date, dag_run_id, layer, check_name, severity,
   rows_affected, observed_value, sample, message, etl_ts)

SELECT @dt, @run_id, 'stage', 'partition_not_empty', 'HIGH',
       0, CAST(stage_rows AS FLOAT64), CAST(NULL AS STRING),
       'Stage partition must contain at least one row for the run date.',
       CURRENT_TIMESTAMP()
FROM _agg WHERE stage_rows = 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'id_not_null', 'HIGH',
       id_not_null_n, CAST(NULL AS FLOAT64), id_not_null_s,
       'id must be present on every row.', CURRENT_TIMESTAMP()
FROM _agg WHERE id_not_null_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'key_not_null', 'HIGH',
       key_not_null_n, CAST(NULL AS FLOAT64), key_not_null_s,
       'key must be present on every row.', CURRENT_TIMESTAMP()
FROM _agg WHERE key_not_null_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'key_format', 'HIGH',
       key_format_n, CAST(NULL AS FLOAT64), key_format_s,
       'key must match PROJECT-NUMBER, e.g. ITV-1453 or S1-1234.', CURRENT_TIMESTAMP()
FROM _agg WHERE key_format_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'id_is_integer', 'HIGH',
       id_is_integer_n, CAST(NULL AS FLOAT64), id_is_integer_s,
       'id must cast to INT64; core.jira_issues.id is INT64.', CURRENT_TIMESTAMP()
FROM _agg WHERE id_is_integer_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'updated_parseable', 'HIGH',
       updated_parseable_n, CAST(NULL AS FLOAT64), updated_parseable_s,
       'fields.updated must parse; the SCD1 merge orders versions on it.', CURRENT_TIMESTAMP()
FROM _agg WHERE updated_parseable_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'payload_not_empty', 'HIGH',
       payload_not_empty_n, CAST(NULL AS FLOAT64), payload_not_empty_s,
       'fields payload must not be null or empty.', CURRENT_TIMESTAMP()
FROM _agg WHERE payload_not_empty_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'project_key_matches', 'MEDIUM',
       project_key_matches_n, CAST(NULL AS FLOAT64), project_key_matches_s,
       'project derived from key must equal fields.project.key.', CURRENT_TIMESTAMP()
FROM _agg WHERE project_key_matches_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'resolved_after_created', 'MEDIUM',
       resolved_after_created_n, CAST(NULL AS FLOAT64), resolved_after_created_s,
       'resolutiondate must not precede created.', CURRENT_TIMESTAMP()
FROM _agg WHERE resolved_after_created_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'created_not_in_future', 'MEDIUM',
       created_not_in_future_n, CAST(NULL AS FLOAT64), created_not_in_future_s,
       'created must not be in the future.', CURRENT_TIMESTAMP()
FROM _agg WHERE created_not_in_future_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'done_has_resolution', 'LOW',
       done_has_resolution_n, CAST(NULL AS FLOAT64), done_has_resolution_s,
       'issues in a terminal status should carry a resolution.', CURRENT_TIMESTAMP()
FROM _agg WHERE done_has_resolution_n > 0

UNION ALL

SELECT @dt, @run_id, 'stage', 'request_type_no_error_stub', 'LOW',
       request_type_no_error_stub_n, CAST(NULL AS FLOAT64), request_type_no_error_stub_s,
       'customfield_10002 must not be a Jira error stub.', CURRENT_TIMESTAMP()
FROM _agg WHERE request_type_no_error_stub_n > 0
;

-- Gate. Runs last, so everything above is durable.
-- ------------------------------------------------------------
SELECT IF(
  failed_n > 0,
  ERROR(FORMAT('DQ HIGH (stage, dt=%t): %d rule(s) violated -> %s',
               @dt, failed_n, failed_rules)),
  'stage DQ passed'
)
FROM (
  SELECT
    COUNT(*) AS failed_n,
    STRING_AGG(FORMAT('%s (%d rows)', check_name, rows_affected), '; '
               ORDER BY check_name) AS failed_rules
  FROM `{{ params.project_id }}.dq.dq_findings`
  WHERE run_date = @dt AND dag_run_id = @run_id
    AND layer = 'stage' AND severity = 'HIGH'
);
