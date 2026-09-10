MERGE `{{ params.project_id }}.core.jira_issues` T
USING (
  WITH parsed AS (
    SELECT
      dt                                                          AS date,
      expand                                                      AS expand,
      SAFE_CAST(id AS INT64)                                      AS id,
      key                                                         AS key,
      self                                                        AS self,
      SPLIT(key, '-')[SAFE_OFFSET(0)]                             AS project,
      JSON_VALUE(fields, '$.project.name')                        AS project_name,
      JSON_VALUE(fields, '$.issuetype.name')                      AS issue_type_name,
      JSON_VALUE(fields, '$.resolution.name')                     AS resolution_name,
      JSON_VALUE(fields, '$.created')                             AS created_date,
      JSON_VALUE(fields, '$.resolutiondate')                      AS resolved_date,
      JSON_VALUE(fields, '$.customfield_11169.value')             AS severity,
      JSON_VALUE(fields, '$.customfield_11067.value')             AS team,
      JSON_VALUE(fields, '$.customfield_11089.value')             AS global_release,
      JSON_VALUE(fields, '$.customfield_10026')                   AS story_points,
      JSON_VALUE(fields, '$.priority.name')                       AS priority,
      JSON_VALUE(fields, '$.customfield_11191.value')             AS bug_type,
      JSON_VALUE(fields, '$.summary')                             AS summary,
      JSON_VALUE(fields, '$.customfield_11137')                   AS testing_scope,
      JSON_VALUE(fields, '$.customfield_11130.value')             AS engineering_area,
      JSON_VALUE(fields, '$.customfield_11132')                   AS automation_test_name,
      JSON_VALUE(fields, '$.status.name')                         AS status,
      JSON_VALUE(fields, '$.reporter.displayName')                AS reporter,
      JSON_VALUE(fields, '$.assignee.displayName')                AS assignee_name,
      JSON_VALUE(fields, '$.customfield_10948')                   AS total_acv,
      JSON_VALUE(fields, '$.customfield_11087.value')             AS program,
      JSON_VALUE(fields, '$.customfield_11104')                   AS execution_comments,
      JSON_VALUE(fields, '$.customfield_11079.value')             AS display_in_big_picture,
      JSON_VALUE(fields, '$.updated')                             AS updated,
      JSON_VALUE(fields, '$.customfield_11099.value')             AS engineering_feedback,
      JSON_VALUE(fields, '$.customfield_11118')                   AS proposed_text_for_limitation_or_resolved_issue,
      JSON_VALUE(fields, '$.customfield_10002.requestType.name')  AS customer_request_type,
      JSON_VALUE(fields, '$.project.projectTypeKey')              AS project_type,
      JSON_VALUE(fields, '$.creator.displayName')                 AS channel,
      -- Merge time, not stage time. Constant across the statement.
      CURRENT_TIMESTAMP()                                         AS etl_ts,
      -- Tie-break only; dropped below.
      payload_hash                                                AS payload_hash
    FROM `{{ params.project_id }}.stage.jira_issues`
    WHERE dt = @dt
  ),
  deduped AS (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY id
        -- Deterministic: 01's dedup makes payload_hash unique within an id.
        ORDER BY SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E3S%z', updated) DESC,
                 payload_hash DESC
      ) AS rn
    FROM parsed
    WHERE id IS NOT NULL  -- 02_dq_stage.sql gates these; backstop only
  )
  SELECT * EXCEPT(rn, payload_hash)
  FROM deduped
  WHERE rn = 1
) S
ON T.id = S.id
-- COALESCE, not a bare `>`: an unparseable side yields NULL, the branch never
-- fires, and the row freezes forever.
WHEN MATCHED AND COALESCE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E3S%z', S.updated),
                          TIMESTAMP('1970-01-01'))
              >  COALESCE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E3S%z', T.updated),
                          TIMESTAMP('1970-01-01'))
THEN UPDATE SET
  date = S.date, expand = S.expand, key = S.key, self = S.self,
  project = S.project, project_name = S.project_name,
  issue_type_name = S.issue_type_name, resolution_name = S.resolution_name,
  created_date = S.created_date, resolved_date = S.resolved_date,
  severity = S.severity, team = S.team, global_release = S.global_release,
  story_points = S.story_points, priority = S.priority, bug_type = S.bug_type,
  summary = S.summary, testing_scope = S.testing_scope,
  engineering_area = S.engineering_area, automation_test_name = S.automation_test_name,
  status = S.status, reporter = S.reporter, assignee_name = S.assignee_name,
  total_acv = S.total_acv, program = S.program,
  execution_comments = S.execution_comments, display_in_big_picture = S.display_in_big_picture,
  updated = S.updated, engineering_feedback = S.engineering_feedback,
  proposed_text_for_limitation_or_resolved_issue = S.proposed_text_for_limitation_or_resolved_issue,
  customer_request_type = S.customer_request_type, project_type = S.project_type,
  channel = S.channel, etl_ts = S.etl_ts
WHEN NOT MATCHED THEN
  INSERT (
    date, expand, id, key, self, project, project_name, issue_type_name,
    resolution_name, created_date, resolved_date, severity, team,
    global_release, story_points, priority, bug_type, summary, testing_scope,
    engineering_area, automation_test_name, status, reporter, assignee_name,
    total_acv, program, execution_comments, display_in_big_picture, updated,
    engineering_feedback, proposed_text_for_limitation_or_resolved_issue,
    customer_request_type, project_type, channel, etl_ts
  )
  VALUES (
    S.date, S.expand, S.id, S.key, S.self, S.project, S.project_name,
    S.issue_type_name, S.resolution_name, S.created_date, S.resolved_date,
    S.severity, S.team, S.global_release, S.story_points, S.priority,
    S.bug_type, S.summary, S.testing_scope, S.engineering_area,
    S.automation_test_name, S.status, S.reporter, S.assignee_name,
    S.total_acv, S.program, S.execution_comments, S.display_in_big_picture,
    S.updated, S.engineering_feedback,
    S.proposed_text_for_limitation_or_resolved_issue,
    S.customer_request_type, S.project_type, S.channel, S.etl_ts
  )
;
