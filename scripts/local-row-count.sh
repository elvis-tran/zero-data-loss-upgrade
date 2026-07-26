#!/usr/bin/env bash

set -euo pipefail

docker run --rm \
  --network zero-data-loss-dev \
  mysql:8.0 \
  mysql \
    -h mysql-dev \
    -uroot \
    -plocal-dev-password \
    -N \
    -e "
      SELECT
        COUNT(*) AS total_rows,
        COUNT(body) AS non_null_body_rows
      FROM notesdb.notes;
    "
