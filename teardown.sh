#!/usr/bin/env bash
# Tear down all tc-upgrade-poc resources
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
load_state

log "=== Teardown ${PROJECT} ==="

# Scale down / delete service
if aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
  --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
  log "Scaling service to 0..."
  aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" --desired-count 0 >/dev/null || true
  sleep 10
  # Stop any remaining tasks
  TASKS=$(aws ecs list-tasks --cluster "${CLUSTER_NAME}" --service-name "${SERVICE_NAME}" --query 'taskArns[]' --output text 2>/dev/null || true)
  if [[ -n "${TASKS}" && "${TASKS}" != "None" ]]; then
    for T in ${TASKS}; do
      aws ecs stop-task --cluster "${CLUSTER_NAME}" --task "${T}" --reason "teardown" >/dev/null || true
    done
  fi
  log "Deleting service..."
  aws ecs delete-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" --force >/dev/null || true
  # Wait until inactive
  for i in $(seq 1 60); do
    ST=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
      --query 'services[0].status' --output text 2>/dev/null || echo MISSING)
    [[ "${ST}" == "INACTIVE" || "${ST}" == "MISSING" || "${ST}" == "None" ]] && break
    sleep 5
  done
  log "Service deleted/inactive."
else
  log "Service not ACTIVE — skip"
fi

# Delete cluster
if aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
  aws ecs delete-cluster --cluster "${CLUSTER_NAME}" >/dev/null || true
  log "Deleted cluster ${CLUSTER_NAME}"
fi

# EFS mount targets then FS
FS_ID="${FS_ID:-}"
if [[ -z "${FS_ID}" || "${FS_ID}" == "None" ]]; then
  FS_ID=$(aws efs describe-file-systems --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId" --output text 2>/dev/null || true)
fi
if [[ -n "${FS_ID}" && "${FS_ID}" != "None" ]]; then
  log "Deleting EFS mount targets for ${FS_ID}..."
  MTS=$(aws efs describe-mount-targets --file-system-id "${FS_ID}" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null || true)
  for MT in ${MTS}; do
    aws efs delete-mount-target --mount-target-id "${MT}" || true
  done
  for i in $(seq 1 60); do
    LEFT=$(aws efs describe-mount-targets --file-system-id "${FS_ID}" --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)
    [[ "${LEFT}" == "0" ]] && break
    sleep 5
  done
  aws efs delete-file-system --file-system-id "${FS_ID}" || true
  log "Deleted EFS ${FS_ID}"
fi

# Security groups (revoke refs first)
TASK_SG="${TASK_SG:-}"
EFS_SG="${EFS_SG:-}"
VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)}"
if [[ -z "${TASK_SG}" || "${TASK_SG}" == "None" ]]; then
  TASK_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_TASK_NAME}" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
fi
if [[ -z "${EFS_SG}" || "${EFS_SG}" == "None" ]]; then
  EFS_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_EFS_NAME}" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
fi
# Revoke EFS ingress from task SG so both can delete
if [[ -n "${EFS_SG}" && "${EFS_SG}" != "None" && -n "${TASK_SG}" && "${TASK_SG}" != "None" ]]; then
  aws ec2 revoke-security-group-ingress --group-id "${EFS_SG}" --protocol tcp --port 2049 --source-group "${TASK_SG}" 2>/dev/null || true
fi
for SG in "${EFS_SG}" "${TASK_SG}"; do
  if [[ -n "${SG}" && "${SG}" != "None" ]]; then
    aws ec2 delete-security-group --group-id "${SG}" 2>/dev/null && log "Deleted SG ${SG}" || log "WARN: could not delete SG ${SG} yet (retry later)"
  fi
done
# Retry SG delete after brief wait (ENI cleanup)
sleep 15
for SG in "${EFS_SG}" "${TASK_SG}"; do
  if [[ -n "${SG}" && "${SG}" != "None" ]]; then
    aws ec2 delete-security-group --group-id "${SG}" 2>/dev/null && log "Deleted SG ${SG} (retry)" || true
  fi
done

# IAM roles
for ROLE in "${EXEC_ROLE_NAME}" "${TASK_ROLE_NAME}"; do
  if aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
    ATTACHED=$(aws iam list-attached-role-policies --role-name "${ROLE}" --query 'AttachedPolicies[].PolicyArn' --output text)
    for P in ${ATTACHED}; do
      aws iam detach-role-policy --role-name "${ROLE}" --policy-arn "${P}" || true
    done
    INLINE=$(aws iam list-role-policies --role-name "${ROLE}" --query 'PolicyNames[]' --output text)
    for P in ${INLINE}; do
      aws iam delete-role-policy --role-name "${ROLE}" --policy-name "${P}" || true
    done
    aws iam delete-role --role-name "${ROLE}" && log "Deleted role ${ROLE}" || log "WARN: delete role ${ROLE} failed"
  fi
done

# CloudWatch log group
aws logs delete-log-group --log-group-name "${LOG_GROUP}" 2>/dev/null && log "Deleted log group ${LOG_GROUP}" || log "Log group already gone"

# ECR repo (force delete images)
if aws ecr describe-repositories --repository-names "${ECR_REPO}" >/dev/null 2>&1; then
  IMAGES=$(aws ecr list-images --repository-name "${ECR_REPO}" --query 'imageIds' --output json)
  if [[ "${IMAGES}" != "[]" ]]; then
    aws ecr batch-delete-image --repository-name "${ECR_REPO}" --image-ids "${IMAGES}" >/dev/null || true
  fi
  aws ecr delete-repository --repository-name "${ECR_REPO}" --force >/dev/null
  log "Deleted ECR repo ${ECR_REPO}"
fi

# Deregister task definitions (optional — mark inactive)
FAMILY_ARNS=$(aws ecs list-task-definitions --family-prefix "${FAMILY}" --query 'taskDefinitionArns[]' --output text 2>/dev/null || true)
for ARN in ${FAMILY_ARNS}; do
  aws ecs deregister-task-definition --task-definition "${ARN}" >/dev/null || true
done
log "Deregistered task definitions for ${FAMILY}"

# Final verification
log "=== Verification ==="
VERIFY_OUT="${PROOF_DIR}/teardown-verify.json"
{
  echo "{"
  echo "  \"cluster\": $(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --query 'clusters[0].status' --output json 2>/dev/null || echo '"MISSING"'),"
  echo "  \"efs\": $(aws efs describe-file-systems --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId" --output json 2>/dev/null || echo '[]'),"
  echo "  \"ecr\": $(aws ecr describe-repositories --repository-names "${ECR_REPO}" --query 'repositories[0].repositoryName' --output json 2>/dev/null || echo 'null'),"
  echo "  \"logGroup\": $(aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --query 'logGroups[0].logGroupName' --output json 2>/dev/null || echo 'null'),"
  echo "  \"taskSg\": $(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_TASK_NAME}" --query 'SecurityGroups[].GroupId' --output json 2>/dev/null || echo '[]'),"
  echo "  \"efsSg\": $(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_EFS_NAME}" --query 'SecurityGroups[].GroupId' --output json 2>/dev/null || echo '[]'),"
  echo "  \"execRole\": $(aws iam get-role --role-name "${EXEC_ROLE_NAME}" --query 'Role.RoleName' --output json 2>/dev/null || echo 'null'),"
  echo "  \"taskRole\": $(aws iam get-role --role-name "${TASK_ROLE_NAME}" --query 'Role.RoleName' --output json 2>/dev/null || echo 'null')"
  echo "}"
} > "${VERIFY_OUT}"
cat "${VERIFY_OUT}"

# Tag-based scan
log "Tag scan Project=${PROJECT}:"
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values="${PROJECT}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output json 2>/dev/null | tee "${PROOF_DIR}/leftover-tagged.json" || echo '[]'

log "=== Teardown complete ==="
