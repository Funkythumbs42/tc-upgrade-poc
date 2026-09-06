#!/usr/bin/env bash
# Upgrade service to v2 and prove stop-before-start + EFS marker persistence
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
load_state

: "${ECR_URI:?missing ECR_URI — run provision.sh first}"
: "${FS_ID:?missing FS_ID}"
: "${EXEC_ROLE_ARN:?missing EXEC_ROLE_ARN}"
: "${TASK_ROLE_ARN:?missing TASK_ROLE_ARN}"

log "=== Upgrade to v2 (stop-before-start) ==="

# Snapshot pre-upgrade state
PRE_TASKS=$(running_task_arns)
PRE_COUNT=$(echo "${PRE_TASKS}" | jq 'length')
PRE_ARN=$(echo "${PRE_TASKS}" | jq -r '.[0] // empty')
log "Pre-upgrade RUNNING count=${PRE_COUNT} task=${PRE_ARN}"
echo "${PRE_TASKS}" > "${PROOF_DIR}/pre-upgrade-tasks.json"
aws ecs describe-tasks --cluster "${CLUSTER_NAME}" --tasks ${PRE_ARN} \
  --query 'tasks[0].{arn:taskArn,lastStatus:lastStatus,startedAt:startedAt,taskDef:taskDefinitionArn}' \
  --output json > "${PROOF_DIR}/pre-upgrade-task-detail.json" 2>/dev/null || true

# Polling timeline file
TIMELINE="${PROOF_DIR}/upgrade-timeline.jsonl"
: > "${TIMELINE}"

record() {
  local note="$1"
  local count arns
  count=$(count_running)
  arns=$(running_task_arns)
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","note":"%s","runningCount":%s,"taskArns":%s}\n' "${ts}" "${note}" "${count}" "${arns}" | tee -a "${TIMELINE}"
  if [[ "${count}" -gt 1 ]]; then
    log "ALERT: runningCount=${count} > 1 — stop-before-start VIOLATED"
    echo "VIOLATION" > "${PROOF_DIR}/STOP_BEFORE_START_VIOLATION"
  fi
}

record "pre-upgrade"

# Register v2 task def (same image, APP_VERSION=v2 — proves env-driven upgrade)
cat > "${SCRIPT_DIR}/taskdef-v2.json" << TDEOF
{
  "family": "${FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "${CPU}",
  "memory": "${MEMORY}",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "${ECR_URI}:v1",
      "essential": true,
      "environment": [
        {"name": "APP_VERSION", "value": "v2"},
        {"name": "DATA_DIR", "value": "/data"},
        {"name": "PORT", "value": "8080"}
      ],
      "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
      "mountPoints": [{"sourceVolume": "efs-data", "containerPath": "/data", "readOnly": false}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "app"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8080/ >/dev/null || exit 1"],
        "interval": 10,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 20
      }
    }
  ],
  "volumes": [
    {
      "name": "efs-data",
      "efsVolumeConfiguration": {
        "fileSystemId": "${FS_ID}",
        "rootDirectory": "/",
        "transitEncryption": "ENABLED"
      }
    }
  ]
}
TDEOF

TD_V2_ARN=$(aws ecs register-task-definition --cli-input-json "file://${SCRIPT_DIR}/taskdef-v2.json" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs tag-resource --resource-arn "${TD_V2_ARN}" \
  --tags key=Project,value="${PROJECT}" key=Owner,value="${OWNER}" key=KeepUntil,value="${KEEP_UNTIL}" 2>/dev/null || true
save_state TD_V2_ARN "${TD_V2_ARN}"
log "Registered v2 task def ${TD_V2_ARN}"
record "v2-taskdef-registered"

# Force new deployment
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${SERVICE_NAME}" \
  --task-definition "${TD_V2_ARN}" \
  --force-new-deployment \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=100,minimumHealthyPercent=0" \
  --query 'service.{taskDef:taskDefinition,deployConfig:deploymentConfiguration,desired:desiredCount}' \
  --output json | tee "${PROOF_DIR}/update-service-response.json"
record "update-service-issued"

# Poll during rollout — prove never 2 RUNNING
log "Polling task counts during upgrade (every 5s, up to ~10 min)..."
MAX_SEEN=0
SEEN_ZERO=0
OLD_STOPPED=0
NEW_RUNNING=0
for i in $(seq 1 120); do
  record "poll-${i}"
  COUNT=$(count_running)
  [[ "${COUNT}" -gt "${MAX_SEEN}" ]] && MAX_SEEN="${COUNT}"
  [[ "${COUNT}" -eq 0 ]] && SEEN_ZERO=1

  # Check stopped tasks that match old ARN
  if [[ -n "${PRE_ARN}" ]]; then
    ST=$(aws ecs describe-tasks --cluster "${CLUSTER_NAME}" --tasks "${PRE_ARN}" \
      --query 'tasks[0].lastStatus' --output text 2>/dev/null || echo UNKNOWN)
    if [[ "${ST}" == "STOPPED" ]]; then
      OLD_STOPPED=1
    fi
  fi

  # Check if new v2 task is running
  CUR=$(running_task_arns)
  NEW_ARN=$(echo "${CUR}" | jq -r '.[0] // empty')
  if [[ -n "${NEW_ARN}" && "${NEW_ARN}" != "${PRE_ARN}" ]]; then
    TD=$(aws ecs describe-tasks --cluster "${CLUSTER_NAME}" --tasks "${NEW_ARN}" \
      --query 'tasks[0].taskDefinitionArn' --output text 2>/dev/null || true)
    if [[ "${TD}" == *":${FAMILY}:"* ]] && [[ "${TD}" == "${TD_V2_ARN}" || "${TD}" == *"${TD_V2_ARN##*:}"* ]]; then
      NEW_RUNNING=1
    fi
    # Also match by revision number from TD_V2_ARN
    REV="${TD_V2_ARN##*:}"
    if echo "${TD}" | grep -q ":${REV}$"; then
      NEW_RUNNING=1
    fi
  fi

  # Capture service events periodically
  if (( i % 6 == 0 )); then
    aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
      --query 'services[0].events[:15]' --output json > "${PROOF_DIR}/service-events.json"
  fi

  # Exit early once stable with new task
  DEPLOYMENTS=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
    --query 'length(services[0].deployments)' --output text)
  RUNNING=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
    --query 'services[0].runningCount' --output text)
  DESIRED=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
    --query 'services[0].desiredCount' --output text)
  PRIMARY_TD=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
    --query 'services[0].taskDefinition' --output text)
  if [[ "${DEPLOYMENTS}" == "1" && "${RUNNING}" == "${DESIRED}" && "${PRIMARY_TD}" == "${TD_V2_ARN}" ]]; then
    record "stable-detected"
    break
  fi
  sleep 5
done

wait_service_stable "${CLUSTER_NAME}" "${SERVICE_NAME}" 300 || true
record "post-stable"

POST_TASKS=$(running_task_arns)
POST_ARN=$(echo "${POST_TASKS}" | jq -r '.[0] // empty')
save_state TD_V2_TASK_ARN "${POST_ARN}"
echo "${POST_TASKS}" > "${PROOF_DIR}/post-upgrade-tasks.json"

aws ecs describe-tasks --cluster "${CLUSTER_NAME}" --tasks ${POST_ARN} \
  --query 'tasks[0].{arn:taskArn,lastStatus:lastStatus,startedAt:startedAt,taskDef:taskDefinitionArn,stoppedReason:stoppedReason}' \
  --output json > "${PROOF_DIR}/post-upgrade-task-detail.json"

# Old task final status
if [[ -n "${PRE_ARN}" ]]; then
  aws ecs describe-tasks --cluster "${CLUSTER_NAME}" --tasks "${PRE_ARN}" \
    --query 'tasks[0].{arn:taskArn,lastStatus:lastStatus,stoppedAt:stoppedAt,startedAt:startedAt,stopCode:stopCode,stoppedReason:stoppedReason}' \
    --output json > "${PROOF_DIR}/old-task-final.json" || true
fi

aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
  --query 'services[0].{deployConfig:deploymentConfiguration,running:runningCount,desired:desiredCount,taskDef:taskDefinition,events:events[:20]}' \
  --output json > "${PROOF_DIR}/post-upgrade-service.json"

# Wait for logs then pull marker evidence
sleep 20
aws logs filter-log-events --log-group-name "${LOG_GROUP}" \
  --start-time $(( ($(date +%s) - 900) * 1000 )) \
  --filter-pattern "MARKER" \
  --query 'events[*].{ts:timestamp,msg:message}' --output json > "${PROOF_DIR}/marker-logs.json" 2>/dev/null || echo '[]' > "${PROOF_DIR}/marker-logs.json"

aws logs filter-log-events --log-group-name "${LOG_GROUP}" \
  --start-time $(( ($(date +%s) - 900) * 1000 )) \
  --limit 100 \
  --query 'events[*].message' --output text > "${PROOF_DIR}/recent-logs.txt" 2>/dev/null || true

# Summarize stop-before-start
MAX_DURING=$(jq -s 'max_by(.runningCount).runningCount' "${TIMELINE}")
HAD_ZERO=$(jq -s 'map(select(.runningCount==0)) | length' "${TIMELINE}")

cat > "${PROOF_DIR}/upgrade-summary.json" << SUM
{
  "preTaskArn": "${PRE_ARN}",
  "postTaskArn": "${POST_ARN}",
  "tdV1": "${TD_V1_ARN:-}",
  "tdV2": "${TD_V2_ARN}",
  "maxRunningSeenDuringUpgrade": ${MAX_DURING},
  "pollsWithZeroRunning": ${HAD_ZERO},
  "stopBeforeStartOk": $([ "${MAX_DURING}" -le 1 ] && echo true || echo false),
  "oldTaskStopped": $([ -f "${PROOF_DIR}/old-task-final.json" ] && jq '.lastStatus=="STOPPED"' "${PROOF_DIR}/old-task-final.json" || echo false),
  "deploymentConfig": {
    "minimumHealthyPercent": 0,
    "maximumPercent": 100,
    "circuitBreaker": {"enable": true, "rollback": true}
  }
}
SUM

log "=== Upgrade complete ==="
log "maxRunningSeen=${MAX_DURING} zeroRunningPolls=${HAD_ZERO}"
cat "${PROOF_DIR}/upgrade-summary.json"
