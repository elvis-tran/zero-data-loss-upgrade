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

DUMP_TIMESTAMP="${1:-$(date -u +%Y%m%d-%H%M%S)}"
export DUMP_TIMESTAMP

GENERATED_DIR="$PROJECT_ROOT/generated"
BACKUP_DIR="$PROJECT_ROOT/evidence/backups"

mkdir -p "$GENERATED_DIR" "$BACKUP_DIR"

echo "Rendering backup Job for timestamp: $DUMP_TIMESTAMP"

envsubst \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME} ${DUMP_TIMESTAMP}' \
  < "$PROJECT_ROOT/manifests/13-backup-job.yaml.template" \
  > "$GENERATED_DIR/13-backup-job.yaml"

kubectl delete job backup-notesdb \
  -n "$NAMESPACE" \
  --ignore-not-found

kubectl apply \
  -f "$GENERATED_DIR/13-backup-job.yaml"

kubectl wait \
  -n "$NAMESPACE" \
  --for=condition=complete \
  job/backup-notesdb \
  --timeout=180s

kubectl logs \
  -n "$NAMESPACE" \
  job/backup-notesdb

kubectl delete pod backup-inspector \
  -n "$NAMESPACE" \
  --ignore-not-found

kubectl run backup-inspector \
  --namespace "$NAMESPACE" \
  --image=mysql:8.0 \
  --restart=Never \
  --overrides="
{
  \"apiVersion\": \"v1\",
  \"spec\": {
    \"nodeSelector\": {
      \"kubernetes.io/hostname\": \"$CLUSTER_NAME-worker\"
    },
    \"containers\": [
      {
        \"name\": \"backup-inspector\",
        \"image\": \"mysql:8.0\",
        \"command\": [\"sleep\", \"3600\"],
        \"volumeMounts\": [
          {
            \"name\": \"backup-storage\",
            \"mountPath\": \"/backup\"
          }
        ]
      }
    ],
    \"volumes\": [
      {
        \"name\": \"backup-storage\",
        \"persistentVolumeClaim\": {
          \"claimName\": \"backup-$STUDENT_ID\"
        }
      }
    ]
  }
}
"

kubectl wait \
  -n "$NAMESPACE" \
  --for=condition=Ready \
  pod/backup-inspector \
  --timeout=120s

DUMP_FILE="notesdb-${DUMP_TIMESTAMP}.sql"
ROWCOUNT_FILE="notesdb-${DUMP_TIMESTAMP}.rowcount"

kubectl exec \
  -n "$NAMESPACE" \
  backup-inspector \
  -- test -s "/backup/$DUMP_FILE"

kubectl cp \
  "$NAMESPACE/backup-inspector:/backup/$DUMP_FILE" \
  "$BACKUP_DIR/$DUMP_FILE"

kubectl cp \
  "$NAMESPACE/backup-inspector:/backup/$ROWCOUNT_FILE" \
  "$BACKUP_DIR/$ROWCOUNT_FILE"

sha256sum \
  "$BACKUP_DIR/$DUMP_FILE" \
  > "$BACKUP_DIR/$DUMP_FILE.sha256"

echo
echo "Backup complete."
echo "Timestamp: $DUMP_TIMESTAMP"
echo "PVC file: /backup/$DUMP_FILE"
echo "Host file: $BACKUP_DIR/$DUMP_FILE"
echo "Expected row count: $(cat "$BACKUP_DIR/$ROWCOUNT_FILE")"
