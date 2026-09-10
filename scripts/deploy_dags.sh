#!/usr/bin/env bash
#
# Deploy the Jira pipeline (DAG + SQL) to the Composer environment's GCS bucket.
#
#   ./scripts/deploy_dags.sh                     # deploy to COMPOSER_BUCKET below
#   ./scripts/deploy_dags.sh other-env-bucket    # deploy to a different bucket
#   ./scripts/deploy_dags.sh --dry-run           # show what would change
#
# Composer is managed outside this repo, so its bucket is a constant here
# rather than something we look up. Find it once with:
#
#   gcloud composer environments describe <env> --location <region> \
#     --format="value(config.dagGcsPrefix)"
#
# and paste the bucket name (without the gs:// prefix or the /dags suffix).

set -euo pipefail

# Composer's own bucket, not the data landing bucket.
COMPOSER_BUCKET="us-central1-airflow-env-tes-a18b0959-bucket" 
# Airflow is shared resource therefore it is expected to maintained from central infra repository

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAGS_SRC="${REPO_ROOT}/etl/airflow/dags"
DAG_FILE="jira_daily_load_dag.py"

# Plain strings, not arrays: bash 3.2 errors on empty array expansion under -u.
DRY_RUN=""
ARG_BUCKET=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="--dry-run" ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) ARG_BUCKET="$arg" ;;
  esac
done

# A bucket passed as an argument wins over the constant above.
BUCKET="${ARG_BUCKET:-$COMPOSER_BUCKET}"
BUCKET="${BUCKET#gs://}"   # tolerate a full gs:// URL
BUCKET="${BUCKET%/}"

if [[ "$BUCKET" == REPLACE-ME-* ]]; then
  echo "error: set COMPOSER_BUCKET in $0, or pass the bucket as an argument." >&2
  exit 1
fi

command -v gcloud >/dev/null || { echo "error: gcloud not found on PATH." >&2; exit 1; }
[[ -f "${DAGS_SRC}/${DAG_FILE}" ]] || { echo "error: missing ${DAGS_SRC}/${DAG_FILE}" >&2; exit 1; }
[[ -d "${DAGS_SRC}/sql" ]]        || { echo "error: missing ${DAGS_SRC}/sql" >&2; exit 1; }

DEST="gs://${BUCKET}/dags"
echo "Deploying to ${DEST}"
echo

# `gcloud storage cp` has no --dry-run, so it is emulated here.
run() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "  would run: $*"
  else
    echo "  $*"
    "$@"
  fi
}

# Copied, not synced: dags/ also holds Composer's airflow_monitoring.py.
# Full object path -- a trailing-slash destination silently does nothing.
echo "==> ${DAG_FILE}"
run gcloud storage cp "${DAGS_SRC}/${DAG_FILE}" "${DEST}/${DAG_FILE}"

# Ours entirely, so mirror exactly -- this is what makes a deleted .sql vanish.
echo "==> sql/"
run gcloud storage rsync "${DAGS_SRC}/sql" "${DEST}/sql" \
  --recursive --delete-unmatched-destination-objects

echo
if [[ -n "$DRY_RUN" ]]; then
  echo "Dry run only. Nothing was uploaded."
  exit 0
fi

# A cp that uploads nothing still exits 0.
echo "==> verifying"
if ! gcloud storage ls "${DEST}/${DAG_FILE}" >/dev/null 2>&1; then
  echo "error: ${DEST}/${DAG_FILE} is not in the bucket after upload." >&2
  exit 1
fi
sql_count=$(gcloud storage ls "${DEST}/sql/**" 2>/dev/null | grep -c '\.sql$' || true)
local_count=$(find "${DAGS_SRC}/sql" -name '*.sql' | wc -l | tr -d ' ')
echo "  ${DAG_FILE}: present"
echo "  sql/: ${sql_count} of ${local_count} .sql files present"
if [[ "$sql_count" != "$local_count" ]]; then
  echo "error: sql file count mismatch." >&2
  exit 1
fi

echo
echo "Uploaded. Composer syncs the bucket to its workers on a delay, so the"
echo "new version typically takes a minute or two to appear in the Airflow UI."
