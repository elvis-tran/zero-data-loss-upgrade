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

MYSQL_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].metadata.name}'
)"

COLUMN_EXISTS="$(
  kubectl exec \
    -n "$NAMESPACE" \
    "$MYSQL_POD" \
    -- sh -c '
      mysql \
        -uroot \
        -p"$MYSQL_ROOT_PASSWORD" \
        -Nse "
          SELECT COUNT(*)
          FROM information_schema.columns
          WHERE table_schema = '\''notesdb'\''
            AND table_name = '\''notes'\''
            AND column_name = '\''body'\'';
        "
    '
)"

if [ "$COLUMN_EXISTS" = "1" ]; then
  NOTE_COLUMN="body"
else
  NOTE_COLUMN="content"
fi

kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c "
    mysql \
      -uroot \
      -p\"\$MYSQL_ROOT_PASSWORD\" \
      -Nse \"
        SELECT
          COUNT(*) AS total_rows,
          COUNT($NOTE_COLUMN) AS non_null_note_rows
        FROM notesdb.notes;
      \"
  "
