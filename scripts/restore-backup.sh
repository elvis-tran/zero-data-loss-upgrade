#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" &&
  pwd
)"

PROJECT_ROOT="$(
  cd "$SCRIPT_DIR/.." &&
  pwd
)"

source "$PROJECT_ROOT/params.env"

DUMP_FILE_PATH="${1:-}"

if [ -z "$DUMP_FILE_PATH" ]; then
  DUMP_FILE_PATH="$(
    find "$PROJECT_ROOT/evidence/backups" \
      -maxdepth 1 \
      -type f \
      -name 'notesdb-*.sql' \
      -printf '%T@ %p\n' \
    | sort -nr \
    | head -1 \
    | cut -d' ' -f2-
  )"
fi

if [ -z "$DUMP_FILE_PATH" ] || [ ! -s "$DUMP_FILE_PATH" ]; then
  echo "No valid backup dump was found."
  exit 1
fi

DUMP_FILENAME="$(basename "$DUMP_FILE_PATH")"
ROWCOUNT_FILE="${DUMP_FILE_PATH%.sql}.rowcount"

if [ ! -s "$ROWCOUNT_FILE" ]; then
  echo "Matching row-count file is missing: $ROWCOUNT_FILE"
  exit 1
fi

EXPECTED_COUNT="$(cat "$ROWCOUNT_FILE")"

export DUMP_FILENAME

echo "Backup file: $DUMP_FILENAME"
echo "Expected row count: $EXPECTED_COUNT"

kubectl scale \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --replicas=0

kubectl wait \
  -n "$NAMESPACE" \
  --for=delete \
  pod \
  -l app=notes-app \
  --timeout=120s || true

envsubst \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME} ${DUMP_FILENAME}' \
  < "$PROJECT_ROOT/manifests/16-restore-job.yaml" \
  > "$PROJECT_ROOT/generated/16-restore-job.yaml"

kubectl delete job restore-notesdb \
  -n "$NAMESPACE" \
  --ignore-not-found

kubectl apply \
  -f "$PROJECT_ROOT/generated/16-restore-job.yaml"

kubectl wait \
  -n "$NAMESPACE" \
  --for=condition=complete \
  job/restore-notesdb \
  --timeout=300s

kubectl logs \
  -n "$NAMESPACE" \
  job/restore-notesdb

kubectl set image \
  deployment/notes-app \
  -n "$NAMESPACE" \
  app="$APP_IMAGE_V1"

kubectl set env \
  deployment/notes-app \
  -n "$NAMESPACE" \
  APP_VERSION=v1 \
  EXPECTED_SCHEMA_VERSION=1

kubectl scale \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --replicas=2

kubectl rollout status \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --timeout=180s

COUNTS="$("$PROJECT_ROOT/scripts/k8s-row-count.sh")"

TOTAL="$(
  printf '%s\n' "$COUNTS" |
  awk '{print $1}'
)"

POPULATED="$(
  printf '%s\n' "$COUNTS" |
  awk '{print $2}'
)"

echo "Restored counts: $COUNTS"

if [ "$TOTAL" != "$EXPECTED_COUNT" ] ||
   [ "$POPULATED" != "$EXPECTED_COUNT" ]; then
  echo "Restore verification failed."
  echo "Expected: $EXPECTED_COUNT $EXPECTED_COUNT"
  echo "Actual:   $TOTAL $POPULATED"
  exit 1
fi

echo "Zero-data-loss restore verification passed."
