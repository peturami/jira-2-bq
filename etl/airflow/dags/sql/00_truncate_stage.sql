-- Full reload of stage. Only fires when the run sets full_load=true.
--
-- TRUNCATE rather than dropping the partition decorator from stage_load: a
-- table-level WRITE_TRUNCATE would replace the Terraform-managed schema.
-- Destructive -- stage is the snapshot history. core is untouched.

{% if params.full_load %}
TRUNCATE TABLE `{{ params.project_id }}.stage.jira_issues`;
{% else %}
-- No-op: keeps this task cheap and always-green on a normal incremental run.
SELECT 1;
{% endif %}
