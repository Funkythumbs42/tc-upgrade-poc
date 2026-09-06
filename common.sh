#!/usr/bin/env bash
# Shared helpers for tc-upgrade-poc
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.env"
export AWS_DEFAULT_REGION="${AWS_REGION}"
STATE_FILE="${SCRIPT_DIR}/.state.env"
PROOF_DIR="${SCRIPT_DIR}/proof"
mkdir -p "${PROOF_DIR}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

save_state() {
  local key="$1" val="$2"
  touch "${STATE_FILE}"
  if grep -q "^export ${key}=" "${STATE_FILE}" 2>/dev/null; then
    sed -i "s|^export ${key}=.*|export ${key}=${val}|" "${STATE_FILE}"
  else
    echo "export ${key}=${val}" >> "${STATE_FILE}"
  fi
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

wait_service_stable() {
  local cluster="$1" service="$2" timeout="${3:-600}"
  log "Waiting for service ${service} to become stable (timeout ${timeout}s)..."
  aws ecs wait services-stable --cluster "${cluster}" --services "${service}" || {
    log "WARN: wait services-stable returned non-zero; checking status..."
    aws ecs describe-services --cluster "${cluster}" --services "${service}" \
      --query 'services[0].{status:status,running:runningCount,desired:desiredCount,deployments:deployments}' --output json
    return 1
  }
  log "Service is stable."
}

running_task_arns() {
  aws ecs list-tasks --cluster "${CLUSTER_NAME}" --service-name "${SERVICE_NAME}" \
    --desired-status RUNNING --query 'taskArns' --output json
}

count_running() {
  running_task_arns | jq 'length'
}
