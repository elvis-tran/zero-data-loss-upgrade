#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" &&
  pwd
)"

cd "$SCRIPT_DIR"

START_SECONDS="$SECONDS"

log() {
  printf '\n[%s] %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code="$?"
  local line_number="$1"

  printf '\nBootstrap failed at line %s with exit code %s.\n' \
    "$line_number" \
    "$exit_code" >&2

  printf '\nCurrent namespace resources:\n' >&2
  kubectl get all -n "${NAMESPACE:-default}" 2>/dev/null || true

  printf '\nRecent namespace events:\n' >&2
  kubectl get events \
    -n "${NAMESPACE:-default}" \
    --sort-by=.lastTimestamp 2>/dev/null \
    | tail -30 || true

  exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Required command is missing: $command_name"
  fi
}

render_template() {
  local source_file="$1"
  local destination_file="$2"
  local variables="$3"

  log "Rendering $(basename "$destination_file")"

  envsubst "$variables" \
    < "$source_file" \
    > "$destination_file"
}

wait_for_job() {
  local job_name="$1"
  local timeout="${2:-180s}"

  log "Waiting for Job $job_name"

  if ! kubectl wait \
    -n "$NAMESPACE" \
    --for=condition=complete \
    "job/$job_name" \
    --timeout="$timeout"
  then
    kubectl describe job "$job_name" \
      -n "$NAMESPACE" || true

    kubectl logs \
      -n "$NAMESPACE" \
      "job/$job_name" \
      --all-containers=true || true

    return 1
  fi

  kubectl logs \
    -n "$NAMESPACE" \
    "job/$job_name" \
    --all-containers=true
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-60}"
  local delay_seconds="${3:-3}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl \
      --fail \
      --silent \
      --show-error \
      --max-time 5 \
      "$url" >/dev/null
    then
      return 0
    fi

    printf 'Waiting for %s (%s/%s)...\n' \
      "$url" \
      "$attempt" \
      "$attempts"

    sleep "$delay_seconds"
  done

  return 1
}

log "Checking prerequisites"

for required_command in \
  docker \
  kind \
  kubectl \
  envsubst \
  curl \
  openssl
do
  require_command "$required_command"
done

if [ ! -f "$SCRIPT_DIR/params.env" ]; then
  fail "params.env was not found."
fi

set -a
source "$SCRIPT_DIR/params.env"
set +a

required_variables=(
  STUDENT_ID
  DOCKER_USER
  NAMESPACE
  CLUSTER_NAME
  APP_IMAGE_V1
  APP_IMAGE_V2
  DATABASE_NAME
  NODE_PORT
  HOST_PORT
)

for variable_name in "${required_variables[@]}"; do
  if [ -z "${!variable_name:-}" ]; then
    fail "Required parameter is empty: $variable_name"
  fi
done

if [ "$NAMESPACE" != "upgrade-$STUDENT_ID" ]; then
  fail "NAMESPACE must equal upgrade-STUDENT_ID."
fi

if [ "$APP_IMAGE_V1" != "docker.io/$DOCKER_USER/notes-app:v1" ]; then
  fail "APP_IMAGE_V1 does not match DOCKER_USER."
fi

if [ "$APP_IMAGE_V2" != "docker.io/$DOCKER_USER/notes-app:v2" ]; then
  fail "APP_IMAGE_V2 does not match DOCKER_USER."
fi

log "Checking Docker"

docker info >/dev/null

log "Checking required Docker Hub image"

docker manifest inspect "$APP_IMAGE_V1" >/dev/null \
  || fail "Cannot access Docker image: $APP_IMAGE_V1"

mkdir -p "$SCRIPT_DIR/generated"

log "Rendering manifests"

render_template \
  "$SCRIPT_DIR/kind-config.yaml" \
  "$SCRIPT_DIR/generated/kind-config.yaml" \
  '${NODE_PORT} ${HOST_PORT}'

render_template \
  "$SCRIPT_DIR/manifests/01-namespace.yaml" \
  "$SCRIPT_DIR/generated/01-namespace.yaml" \
  '${NAMESPACE} ${STUDENT_ID}'

render_template \
  "$SCRIPT_DIR/manifests/02-mysql-config.yaml" \
  "$SCRIPT_DIR/generated/02-mysql-config.yaml" \
  '${NAMESPACE} ${DATABASE_NAME}'

render_template \
  "$SCRIPT_DIR/manifests/03-mysql-pvc.yaml" \
  "$SCRIPT_DIR/generated/03-mysql-pvc.yaml" \
  '${STUDENT_ID} ${NAMESPACE}'

render_template \
  "$SCRIPT_DIR/manifests/04-mysql-deployment.yaml" \
  "$SCRIPT_DIR/generated/04-mysql-deployment.yaml" \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME}'

render_template \
  "$SCRIPT_DIR/manifests/05-mysql-service.yaml" \
  "$SCRIPT_DIR/generated/05-mysql-service.yaml" \
  '${NAMESPACE}'

render_template \
  "$SCRIPT_DIR/manifests/06-migration-v1-configmap.yaml" \
  "$SCRIPT_DIR/generated/06-migration-v1-configmap.yaml" \
  '${NAMESPACE}'

render_template \
  "$SCRIPT_DIR/manifests/07-migrate-v1-job.yaml" \
  "$SCRIPT_DIR/generated/07-migrate-v1-job.yaml" \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME}'

render_template \
  "$SCRIPT_DIR/manifests/08-seed-configmap.yaml" \
  "$SCRIPT_DIR/generated/08-seed-configmap.yaml" \
  '${NAMESPACE} ${STUDENT_ID}'

render_template \
  "$SCRIPT_DIR/manifests/09-seed-job.yaml" \
  "$SCRIPT_DIR/generated/09-seed-job.yaml" \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME}'

render_template \
  "$SCRIPT_DIR/manifests/10-notes-app-deployment.yaml" \
  "$SCRIPT_DIR/generated/10-notes-app-deployment.yaml" \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME} ${APP_IMAGE_V1}'

render_template \
  "$SCRIPT_DIR/manifests/11-notes-app-service.yaml" \
  "$SCRIPT_DIR/generated/11-notes-app-service.yaml" \
  '${NAMESPACE} ${NODE_PORT}'

render_template \
  "$SCRIPT_DIR/manifests/12-backup-pvc.yaml" \
  "$SCRIPT_DIR/generated/12-backup-pvc.yaml" \
  '${STUDENT_ID} ${NAMESPACE}'

render_template \
  "$SCRIPT_DIR/manifests/14-migration-v2-configmap.yaml" \
  "$SCRIPT_DIR/generated/14-migration-v2-configmap.yaml" \
  '${NAMESPACE}'

render_template \
  "$SCRIPT_DIR/manifests/15-migrate-v2-job.yaml" \
  "$SCRIPT_DIR/generated/15-migrate-v2-job.yaml" \
  '${NAMESPACE} ${STUDENT_ID} ${CLUSTER_NAME}'

log "Checking the Kind cluster"

if kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
  log "Cluster $CLUSTER_NAME already exists; reusing it."
else
  log "Creating Kind cluster $CLUSTER_NAME"

  kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "$SCRIPT_DIR/generated/kind-config.yaml"
fi

EXPECTED_CONTEXT="kind-$CLUSTER_NAME"
CURRENT_CONTEXT="$(kubectl config current-context)"

if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
  log "Switching kubectl context to $EXPECTED_CONTEXT"
  kubectl config use-context "$EXPECTED_CONTEXT"
fi

log "Waiting for Kubernetes nodes"

kubectl wait \
  --for=condition=Ready \
  nodes \
  --all \
  --timeout=180s

NODE_COUNT="$(
  kubectl get nodes \
    --no-headers \
    | wc -l \
    | tr -d ' '
)"

if [ "$NODE_COUNT" -ne 2 ]; then
  fail "Expected exactly 2 Kubernetes nodes, found $NODE_COUNT."
fi

log "Applying namespace"

kubectl apply \
  -f "$SCRIPT_DIR/generated/01-namespace.yaml"

log "Creating or preserving MySQL credentials"

SECRET_NAME="mysql-creds-$STUDENT_ID"

if kubectl get secret "$SECRET_NAME" \
  -n "$NAMESPACE" >/dev/null 2>&1
then
  log "Secret $SECRET_NAME already exists; preserving it."
else
  MYSQL_ROOT_PASSWORD="$(
    openssl rand -base64 36 |
    tr -d '\n/=+' |
    cut -c1-32
  )"

  MYSQL_APP_PASSWORD="$(
    openssl rand -base64 36 |
    tr -d '\n/=+' |
    cut -c1-32
  )"

  MYSQL_APP_USER="notesuser"

  kubectl create secret generic "$SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --from-literal=MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
    --from-literal=MYSQL_USER="$MYSQL_APP_USER" \
    --from-literal=MYSQL_PASSWORD="$MYSQL_APP_PASSWORD"
fi

log "Applying MySQL configuration and storage"

kubectl apply \
  -f "$SCRIPT_DIR/generated/02-mysql-config.yaml"

kubectl apply \
  -f "$SCRIPT_DIR/generated/03-mysql-pvc.yaml"

kubectl apply \
  -f "$SCRIPT_DIR/generated/05-mysql-service.yaml"

kubectl apply \
  -f "$SCRIPT_DIR/generated/04-mysql-deployment.yaml"

log "Waiting for MySQL Deployment"

kubectl rollout status \
  deployment/mysql \
  -n "$NAMESPACE" \
  --timeout=240s

MYSQL_NODE="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    -o jsonpath='{.items[0].spec.nodeName}'
)"

EXPECTED_WORKER="$CLUSTER_NAME-worker"

if [ "$MYSQL_NODE" != "$EXPECTED_WORKER" ]; then
  fail "MySQL was scheduled on $MYSQL_NODE, expected $EXPECTED_WORKER."
fi

log "Applying migration v1 SQL ConfigMap"

kubectl apply \
  -f "$SCRIPT_DIR/generated/06-migration-v1-configmap.yaml"

log "Running migration v1"

kubectl delete job migrate-v1 \
  -n "$NAMESPACE" \
  --ignore-not-found \
  --wait=true

kubectl apply \
  -f "$SCRIPT_DIR/generated/07-migrate-v1-job.yaml"

wait_for_job migrate-v1 180s

log "Applying seed SQL ConfigMap"

kubectl apply \
  -f "$SCRIPT_DIR/generated/08-seed-configmap.yaml"

log "Running seed Job"

kubectl delete job seed-notes \
  -n "$NAMESPACE" \
  --ignore-not-found \
  --wait=true

kubectl apply \
  -f "$SCRIPT_DIR/generated/09-seed-job.yaml"

wait_for_job seed-notes 180s

log "Applying backup PVC"

kubectl apply \
  -f "$SCRIPT_DIR/generated/12-backup-pvc.yaml"

log "Preparing v2 migration ConfigMap without running it"

kubectl apply \
  -f "$SCRIPT_DIR/generated/14-migration-v2-configmap.yaml"

log "Deploying Notes app v1"

kubectl apply \
  -f "$SCRIPT_DIR/generated/10-notes-app-deployment.yaml"

kubectl apply \
  -f "$SCRIPT_DIR/generated/11-notes-app-service.yaml"

kubectl rollout status \
  deployment/notes-app \
  -n "$NAMESPACE" \
  --timeout=240s

APP_NODE_COUNT="$(
  kubectl get pod \
    -n "$NAMESPACE" \
    -l app=notes-app \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | grep -Fxc "$EXPECTED_WORKER"
)"

if [ "$APP_NODE_COUNT" -ne 2 ]; then
  fail "Expected both Notes app Pods on $EXPECTED_WORKER."
fi

APP_URL="http://localhost:$HOST_PORT"

log "Waiting for Notes app at $APP_URL"

wait_for_http "$APP_URL/ready" 80 3 \
  || fail "Notes app did not become Ready at $APP_URL."

log "Verifying readiness response"

READY_RESPONSE="$(
  curl \
    --fail \
    --silent \
    --show-error \
    "$APP_URL/ready"
)"

printf '%s\n' "$READY_RESPONSE"

printf '%s\n' "$READY_RESPONSE" \
  | grep -q '"app_version":"v1"' \
  || fail "Readiness response does not report app v1."

printf '%s\n' "$READY_RESPONSE" \
  | grep -q '"schema_version":1' \
  || fail "Readiness response does not report schema version 1."

log "Verifying application banner"

PAGE_CONTENT="$(
  curl \
    --fail \
    --silent \
    --show-error \
    "$APP_URL/"
)"

printf '%s\n' "$PAGE_CONTENT" \
  | grep -q "Served by $STUDENT_ID" \
  || fail "Application page does not contain the student ID."

printf '%s\n' "$PAGE_CONTENT" \
  | grep -q "app v1" \
  || fail "Application page does not report app v1."

printf '%s\n' "$PAGE_CONTENT" \
  | grep -q "schema v1" \
  || fail "Application page does not report schema v1."

log "Verifying row counts"

ROW_COUNTS="$(
  "$SCRIPT_DIR/scripts/k8s-row-count.sh" 2>/dev/null
)"

printf 'Row counts: %s\n' "$ROW_COUNTS"

TOTAL_ROWS="$(
  printf '%s\n' "$ROW_COUNTS" |
  awk '{print $1}'
)"

POPULATED_ROWS="$(
  printf '%s\n' "$ROW_COUNTS" |
  awk '{print $2}'
)"

if [ "$TOTAL_ROWS" -lt 20 ]; then
  fail "Expected at least 20 rows, found $TOTAL_ROWS."
fi

if [ "$TOTAL_ROWS" != "$POPULATED_ROWS" ]; then
  fail "Row-count verification failed: $ROW_COUNTS"
fi

STUDENT_ROW_COUNT="$(
  MYSQL_POD="$(
    kubectl get pod \
      -n "$NAMESPACE" \
      -l app=mysql \
      -o jsonpath='{.items[0].metadata.name}'
  )"

  kubectl exec \
    -n "$NAMESPACE" \
    "$MYSQL_POD" \
    -- sh -c "
      mysql \
        -uroot \
        -p\"\$MYSQL_ROOT_PASSWORD\" \
        -Nse \"
          SELECT COUNT(*)
          FROM notesdb.notes
          WHERE author = '$STUDENT_ID';
        \"
    " 2>/dev/null
)"

if [ "$STUDENT_ROW_COUNT" -lt 20 ]; then
  fail "Expected at least 20 student-authored rows, found $STUDENT_ROW_COUNT."
fi

ELAPSED_SECONDS="$((SECONDS - START_SECONDS))"

log "Bootstrap completed successfully"

printf '\n'
printf 'Cluster:               %s\n' "$CLUSTER_NAME"
printf 'Namespace:             %s\n' "$NAMESPACE"
printf 'Application URL:       %s\n' "$APP_URL"
printf 'Schema version:        1\n'
printf 'Total rows:            %s\n' "$TOTAL_ROWS"
printf 'Student-authored rows: %s\n' "$STUDENT_ROW_COUNT"
printf 'Elapsed seconds:       %s\n' "$ELAPSED_SECONDS"

if [ "$ELAPSED_SECONDS" -ge 900 ]; then
  printf '\nWARNING: Bootstrap exceeded the 15-minute target.\n'
fi
