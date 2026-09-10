-- Raw holds the current snapshot only, so no WHERE clause is needed. If raw
-- ever becomes append-across-runs this needs a batch filter.
--
-- A bare SELECT, not an INSERT: the DAG writes it into
-- stage.jira_issues$<partition> with WRITE_TRUNCATE.

SELECT
    expand,
    id,
    self,
    key,
    fields,
    payload_hash,
    @dt AS dt,
    -- dt is rewritten by a backfill; etl_ts is not.
    CURRENT_TIMESTAMP() AS etl_ts
FROM (
    SELECT
        expand,
        id,
        self,
        key,
        fields,
        FARM_FINGERPRINT(TO_JSON_STRING(fields)) AS payload_hash
    FROM `{{ params.project_id }}.raw.jira_issues`
)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY id, key, payload_hash
    ORDER BY id  -- rows in a group are already identical on the partition key
) = 1
