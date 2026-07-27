# Zero-Data-Loss Notes App Upgrade Runbook

## Project Information

- Repository directory: `~/zero-data-loss-upgrade`
- Kind cluster: `zero-data-loss`
- Namespace: `upgrade-etran12`
- Student ID: `etran12`
- Docker Hub user: `elvistrann7`
- Application URL: `http://localhost:8080`
- App v1 image: `docker.io/elvistrann7/notes-app:v1`
- App v2 image: `docker.io/elvistrann7/notes-app:v2`

This runbook contains the tested commands used to:

1. Bootstrap the v1 environment.
2. Verify the application and database.
3. Take a fresh pre-upgrade backup.
4. Upgrade from v1 to v2.
5. Detect the deliberately introduced data corruption.
6. Decide whether rollback, restore, or both are required.
7. Restore the database with zero lost pre-upgrade rows.
8. Return the application to a healthy v1 state.

All commands are run from WSL.

---

# 1. Load Project Parameters

Run this at the beginning of every new WSL terminal session:

```bash
cd ~/zero-data-loss-upgrade

set -a
source params.env
set +a
```

Verify the values:

```bash
printf 'Student ID: %s\nNamespace: %s\nCluster: %s\nDocker user: %s\n' \
  "$STUDENT_ID" \
  "$NAMESPACE" \
  "$CLUSTER_NAME" \
  "$DOCKER_USER"
```

Expected values:

```text
Student ID: etran12
Namespace: upgrade-etran12
Cluster: zero-data-loss
Docker user: elvistrann7
```

Confirm the active Kubernetes context:

```bash
kubectl config current-context
```

Expected:

```text
kind-zero-data-loss
```

If necessary, switch to it:

```bash
kubectl config use-context "kind-$CLUSTER_NAME"
```

---

# 2. Bootstrap the v1 Environment

Run:

```bash
./bootstrap.sh
```

Verify the nodes:

```bash
kubectl get nodes -o wide
```

Expected:

- `zero-data-loss-control-plane` is Ready.
- `zero-data-loss-worker` is Ready.

Verify project resources:

```bash
kubectl get all -n "$NAMESPACE"
kubectl get pvc -n "$NAMESPACE"
```

Verify Pod scheduling:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -o wide
```

Expected:

- MySQL runs on `zero-data-loss-worker`.
- Both Notes app Pods run on `zero-data-loss-worker`.
- Both Notes app Pods show `1/1 Running`.
- The MySQL PVC is `Bound`.
- The backup PVC is present.

Verify the app:

```bash
curl -i "http://localhost:$HOST_PORT/ready"
```

Expected:

```text
HTTP/1.1 200 OK
```

Expected JSON:

```json
{"app_version":"v1","schema_version":1,"status":"ready"}
```

Verify the row counts:

```bash
./scripts/k8s-row-count.sh
```

Expected initial result:

```text
20	20
```

Verify the schema and student-authored rows:

```bash
MYSQL_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].metadata.name}'
)"
```

```bash
kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c "
    mysql \
      -uroot \
      -p\"\$MYSQL_ROOT_PASSWORD\" \
      -e \"
        SELECT version
        FROM notesdb.schema_version;

        SELECT COUNT(*) AS student_rows
        FROM notesdb.notes
        WHERE author = '$STUDENT_ID';
      \"
  "
```

Expected:

- `schema_version = 1`
- At least 20 rows authored by `etran12`

Open the application:

```text
http://localhost:8080
```

Expected banner:

```text
Served by etran12 - app v1 - schema v1
```

---

# 3. Show the Migration Design

Display migration v1:

```bash
cat migrations/001_init.sql
```

Display the deliberately broken migration v2:

```bash
cat migrations/002_v2.sql
```

Important v2 statements:

```sql
ALTER TABLE notes
ADD COLUMN content TEXT NULL AFTER author;

UPDATE notes
SET content = body
WHERE id <= 10;

ALTER TABLE notes
DROP COLUMN body;

UPDATE schema_version
SET version = 2;
```

Expected result:

- Total rows remain unchanged.
- IDs 1 through 10 retain note content.
- IDs greater than 10 have `NULL content`.
- The migration exits successfully.
- `schema_version` becomes 2.
- A successful exit code does not prove data integrity.

---

# 4. Record the Live Pre-Upgrade State

```text
http://localhost:8080
```

Run:

```bash
PRE_UPGRADE_COUNTS="$(./scripts/k8s-row-count.sh)"
echo "$PRE_UPGRADE_COUNTS"
```

Store the total:

```bash
PRE_UPGRADE_TOTAL="$(
  printf '%s\n' "$PRE_UPGRADE_COUNTS" |
  awk '{print $1}'
)"

echo "Pre-upgrade total rows: $PRE_UPGRADE_TOTAL"
```

Confirm both counts match:

```bash
PRE_UPGRADE_POPULATED="$(
  printf '%s\n' "$PRE_UPGRADE_COUNTS" |
  awk '{print $2}'
)"

test "$PRE_UPGRADE_TOTAL" = "$PRE_UPGRADE_POPULATED" \
  && echo "Pre-upgrade data is fully populated."
```

Display the newest rows:

```bash
MYSQL_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].metadata.name}'
)"
```

```bash
kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c '
    mysql \
      -uroot \
      -p"$MYSQL_ROOT_PASSWORD" \
      -e "
        SELECT id, author, body, created_at
        FROM notesdb.notes
        ORDER BY id DESC
        LIMIT 10;
      "
  '
```

---

# 5. Take the Pre-Upgrade Backup

Run:

```bash
./scripts/take-backup.sh
```

Confirm the backup Job completed:

```bash
kubectl get job backup-notesdb \
  -n "$NAMESPACE"
```

View the logs:

```bash
kubectl logs \
  -n "$NAMESPACE" \
  job/backup-notesdb
```

Find the latest host dump:

```bash
LATEST_DUMP="$(
  find evidence/backups \
    -maxdepth 1 \
    -type f \
    -name 'notesdb-*.sql' \
    -printf '%T@ %p\n' \
  | sort -nr \
  | head -1 \
  | cut -d' ' -f2-
)"

echo "$LATEST_DUMP"
```

Verify it exists and is non-empty:

```bash
test -n "$LATEST_DUMP"
test -s "$LATEST_DUMP"

echo "Verified non-empty dump: $LATEST_DUMP"
```

Find the matching row-count file:

```bash
LATEST_ROWCOUNT="${LATEST_DUMP%.sql}.rowcount"
BACKUP_ROW_COUNT="$(cat "$LATEST_ROWCOUNT")"

echo "Live pre-upgrade total: $PRE_UPGRADE_TOTAL"
echo "Backup row count:       $BACKUP_ROW_COUNT"
```

Require an exact match:

```bash
test "$BACKUP_ROW_COUNT" = "$PRE_UPGRADE_TOTAL" \
  && echo "Backup row count matches live row count."
```

Verify the dump checksum:

```bash
sha256sum -c "${LATEST_DUMP}.sha256"
```

Expected:

```text
OK
```

Confirm that the dump contains the Notes table:

```bash
grep -n \
  'CREATE TABLE `notes`' \
  "$LATEST_DUMP"
```

Confirm that the dump contains note data:

```bash
grep -n \
  'INSERT INTO `notes`' \
  "$LATEST_DUMP" \
  | head -1
```

Confirm that the student ID appears in the dump:

```bash
grep -F \
  "$STUDENT_ID" \
  "$LATEST_DUMP" \
  | head -1
```

Do not run migration v2 unless:

- The dump exists.
- The dump is non-empty.
- The checksum passes.
- The backup count equals the current live count.
- The live-added rows are represented in the dump.

---

# 6. Inspect the State Before Any Upgrade or Recovery Decision

Check the migration Job:

```bash
kubectl get job migrate-v2 \
  -n "$NAMESPACE" \
  || true
```

Check all Pods:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -o wide
```

Check the Deployment rollout:

```bash
kubectl rollout status \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --timeout=20s \
  || true
```

Run the row-count proof:

```bash
./scripts/k8s-row-count.sh
```

Inspect schema version and columns:

```bash
MYSQL_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].metadata.name}'
)"
```

```bash
kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c '
    mysql \
      -uroot \
      -p"$MYSQL_ROOT_PASSWORD" \
      -e "
        SELECT version
        FROM notesdb.schema_version;

        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = '\''notesdb'\''
          AND table_name = '\''notes'\''
        ORDER BY ordinal_position;
      "
  '
```

---

# 7. Upgrade v1 to v2

Delete a previous migration Job if one exists:

```bash
kubectl delete job migrate-v2 \
  -n "$NAMESPACE" \
  --ignore-not-found
```

Apply migration v2:

```bash
kubectl apply \
  -f generated/15-migrate-v2-job.yaml
```

Watch the migration Pod:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -l job-name=migrate-v2 \
  -w
```

Wait for Job completion:

```bash
kubectl wait \
  -n "$NAMESPACE" \
  --for=condition=complete \
  job/migrate-v2 \
  --timeout=180s
```

View the migration logs:

```bash
kubectl logs \
  -n "$NAMESPACE" \
  job/migrate-v2
```

Render the v2 Deployment manifest:

```bash
envsubst \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME} ${APP_IMAGE_V2}' \
  < manifests/17-notes-app-v2-deployment.yaml \
  > generated/17-notes-app-v2-deployment.yaml
```

Apply app v2:

```bash
kubectl apply \
  -f generated/17-notes-app-v2-deployment.yaml
```

Wait for the rollout:

```bash
kubectl rollout status \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --timeout=180s
```

Confirm the images:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -l app=notes-app \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
```

Expected image:

```text
docker.io/elvistrann7/notes-app:v2
```

---

# 8. Detect the Data Damage

Check readiness:

```bash
curl -i "http://localhost:$HOST_PORT/ready"
```

Expected:

```json
{"app_version":"v2","schema_version":2,"status":"ready"}
```

Run the row-count proof:

```bash
DAMAGED_COUNTS="$(./scripts/k8s-row-count.sh)"
echo "$DAMAGED_COUNTS"
```

Expected pattern:

```text
<pre-upgrade total>	10
```

Inspect damaged rows:

```bash
MYSQL_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].metadata.name}'
)"
```

```bash
kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c '
    mysql \
      -uroot \
      -p"$MYSQL_ROOT_PASSWORD" \
      -e "
        SELECT version
        FROM notesdb.schema_version;

        SELECT id, author, content
        FROM notesdb.notes
        WHERE id > 10
        ORDER BY id;
      "
  '
```

Count the NULL values:

```bash
kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c '
    mysql \
      -uroot \
      -p"$MYSQL_ROOT_PASSWORD" \
      -Nse "
        SELECT COUNT(*)
        FROM notesdb.notes
        WHERE content IS NULL;
      "
  '
```

> The migration completed and the schema now reports version 2, but the populated-content count proves data was lost. A successful Job and compatible schema do not prove data integrity.

---

# 9. Demonstrate Application Rollback

View Deployment history:

```bash
kubectl rollout history \
  deployment/notes-app \
  -n "$NAMESPACE"
```

> Deployment history records application Pod-template revisions. It does not record database schema changes, deleted column values, row counts, backup state, or data integrity.

Run:

```bash
kubectl rollout undo \
  deployment/notes-app \
  -n "$NAMESPACE"
```

Check the Pods:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -l app=notes-app \
  -w
```

Press `Ctrl+C` after observing the state.

Check rollout status:

```bash
kubectl rollout status \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --timeout=30s \
  || true
```

Run the row-count proof again:

```bash
./scripts/k8s-row-count.sh
```

## Expected result

- The database is still schema version 2.
- The `body` column is still missing.
- The damaged values remain lost.
- v1 Pods cannot become Ready against schema version 2.
- Application rollback alone is insufficient.

---

# 10. Restore the Database

## Recovery decision

Find the latest verified backup:

```bash
LATEST_DUMP="$(
  find evidence/backups \
    -maxdepth 1 \
    -type f \
    -name 'notesdb-*.sql' \
    -printf '%T@ %p\n' \
  | sort -nr \
  | head -1 \
  | cut -d' ' -f2-
)"

echo "$LATEST_DUMP"
```

Verify:

```bash
test -s "$LATEST_DUMP"
sha256sum -c "${LATEST_DUMP}.sha256"
```

Read the expected count:

```bash
BACKUP_ROWCOUNT_FILE="${LATEST_DUMP%.sql}.rowcount"
EXPECTED_RESTORE_COUNT="$(cat "$BACKUP_ROWCOUNT_FILE")"

echo "Expected restored rows: $EXPECTED_RESTORE_COUNT"
```

Run:

```bash
./scripts/restore-backup.sh "$LATEST_DUMP"
```

View the restore Job:

```bash
kubectl get job restore-notesdb \
  -n "$NAMESPACE"
```

View the restore logs:

```bash
kubectl logs \
  -n "$NAMESPACE" \
  job/restore-notesdb
```

---

# 11. Final Zero-Data-Loss Verification

Check app readiness:

```bash
curl -i "http://localhost:$HOST_PORT/ready"
```

Expected:

```json
{"app_version":"v1","schema_version":1,"status":"ready"}
```

Run the final row-count proof:

```bash
FINAL_COUNTS="$(./scripts/k8s-row-count.sh)"
echo "$FINAL_COUNTS"
```

Extract the results:

```bash
FINAL_TOTAL="$(
  printf '%s\n' "$FINAL_COUNTS" |
  awk '{print $1}'
)"

FINAL_POPULATED="$(
  printf '%s\n' "$FINAL_COUNTS" |
  awk '{print $2}'
)"
```

Compare against the verified backup:

```bash
test "$FINAL_TOTAL" = "$EXPECTED_RESTORE_COUNT"
test "$FINAL_POPULATED" = "$EXPECTED_RESTORE_COUNT"

echo "Zero-data-loss verification passed."
```

Verify schema version and columns:

```bash
MYSQL_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].metadata.name}'
)"
```

```bash
kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c '
    mysql \
      -uroot \
      -p"$MYSQL_ROOT_PASSWORD" \
      -e "
        SELECT version
        FROM notesdb.schema_version;

        DESCRIBE notesdb.notes;
      "
  '
```

Expected:

```text
schema_version = 1
```

Expected columns:

```text
id
author
body
created_at
```

Verify app Pods:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -l app=notes-app \
  -o wide
```

Expected:

- Two Pods
- Both `1/1 Running`
- Both on `zero-data-loss-worker`

Verify the banner in the browser:

```text
http://localhost:8080
```

Expected:

```text
Served by etran12 - app v1 - schema v1
```

---

# 12. Rollback-versus-Restore Decision Table

| Observed state | Is rollout undo alone safe? | Correct action | Reason |
|---|---|---|---|
| Migration Job has not started | Yes | Cancel or undo the Deployment change | The database remains at schema version 1 and no migration SQL has executed |
| App v2 was deployed before migration | Yes, if schema remains v1 | Undo the Deployment or leave v2 NotReady | The v2 readiness gate prevents traffic while schema version remains 1 |
| Migration Pod started but was interrupted | No, not without inspection | Inspect schema version, columns, and counts; normally restore the verified backup | MySQL DDL statements may commit independently, leaving a partially migrated schema |
| Migration completed and schema version is 2 | No | Restore the database and return the app to v1 | The original body column was dropped and values after ID 10 were lost |
| Migration completed but app rollout was interrupted | No | Restore the database and return the Deployment to v1 | The database damage occurred before or independently of the Deployment rollout |
| Deployment rollback completed but database remains schema v2 | No | Scale the app down and restore the backup | Rollback changed application configuration only and did not restore data |

---

# 13. Interrupted Migration Diagnosis

If the migration Pod is deleted during the migration, do not immediately rerun the Job.

Identify the migration Pod:

```bash
MIGRATION_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l job-name=migrate-v2 \
    -o jsonpath='{.items[0].metadata.name}'
)"

echo "$MIGRATION_POD"
```

Inspect the Job:

```bash
kubectl get job migrate-v2 \
  -n "$NAMESPACE"

kubectl describe job migrate-v2 \
  -n "$NAMESPACE"
```

Inspect database columns and schema version:

```bash
MYSQL_POD="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].metadata.name}'
)"
```

```bash
kubectl exec \
  -n "$NAMESPACE" \
  "$MYSQL_POD" \
  -- sh -c '
    mysql \
      -uroot \
      -p"$MYSQL_ROOT_PASSWORD" \
      -e "
        SELECT version
        FROM notesdb.schema_version;

        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = '\''notesdb'\''
          AND table_name = '\''notes'\''
        ORDER BY ordinal_position;

        SELECT
          COUNT(*) AS total_rows,
          COUNT(body) AS populated_body,
          COUNT(content) AS populated_content
        FROM notesdb.notes;
      "
  '
```

A possible interrupted state is:

- `schema_version = 1`
- Both `body` and `content` exist
- IDs 1 through 10 were copied
- IDs greater than 10 have NULL `content`
- The migration Job failed or was deleted

Run:

```bash
LATEST_DUMP="$(
  find evidence/backups \
    -maxdepth 1 \
    -type f \
    -name 'notesdb-*.sql' \
    -printf '%T@ %p\n' \
  | sort -nr \
  | head -1 \
  | cut -d' ' -f2-
)"

./scripts/restore-backup.sh "$LATEST_DUMP"
```

---

# 14. Deployment Rollout Interruption Diagnosis

Inspect the Pods:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -l app=notes-app \
  -o wide
```

Check each Pod image:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -l app=notes-app \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"  Ready="}{range .status.containerStatuses[*]}{.ready}{end}{"\n"}{end}'
```

Check the rollout:

```bash
kubectl rollout status \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --timeout=20s \
  || true
```

Check the database:

```bash
./scripts/k8s-row-count.sh
```

---

# 15. Rollout History Explanation

Run:

```bash
kubectl rollout history \
  deployment/notes-app \
  -n "$NAMESPACE"
```

---

# 16. Useful Status Commands

Show all namespace resources:

```bash
kubectl get all -n "$NAMESPACE"
```

Show storage:

```bash
kubectl get pvc -n "$NAMESPACE"
```

Show Pods and nodes:

```bash
kubectl get pods \
  -n "$NAMESPACE" \
  -o wide
```

Show app Service endpoints:

```bash
kubectl get endpoints notes-app-svc \
  -n "$NAMESPACE"
```

Show Deployment history:

```bash
kubectl rollout history \
  deployment/notes-app \
  -n "$NAMESPACE"
```

Show migration logs:

```bash
kubectl logs \
  -n "$NAMESPACE" \
  job/migrate-v2
```

Show backup logs:

```bash
kubectl logs \
  -n "$NAMESPACE" \
  job/backup-notesdb
```

Show restore logs:

```bash
kubectl logs \
  -n "$NAMESPACE" \
  job/restore-notesdb
```

Run the row-count proof:

```bash
./scripts/k8s-row-count.sh
```

Check application readiness:

```bash
curl -i "http://localhost:$HOST_PORT/ready"
```

---

# 17. Clean Cluster Rebuild

This deletes all Kubernetes resources and PVC data in the Kind cluster:

```bash
kind delete cluster \
  --name "$CLUSTER_NAME"
```

Rebuild:

```bash
./bootstrap.sh
```

Verify:

```bash
kubectl get all -n "$NAMESPACE"
kubectl get pvc -n "$NAMESPACE"
curl -i "http://localhost:$HOST_PORT/ready"
./scripts/k8s-row-count.sh
```
