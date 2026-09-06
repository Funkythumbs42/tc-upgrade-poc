#!/usr/bin/env bash
# Provision ECS Fargate + EFS stand-in for TeamCity stop-before-start upgrade POC
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
load_state

log "=== Provisioning ${PROJECT} in ${AWS_REGION} ==="

# --- VPC / subnets (default VPC public) ---
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text)
SUBNET_ARR=($SUBNETS)
# EFS needs mount targets in >=2 AZs; service can use 2 subnets
SUBNET1="${SUBNET_ARR[0]}"
SUBNET2="${SUBNET_ARR[1]}"
SUBNET3="${SUBNET_ARR[2]:-${SUBNET_ARR[0]}}"
log "VPC=${VPC_ID} subnets=${SUBNET1},${SUBNET2},${SUBNET3}"
save_state VPC_ID "${VPC_ID}"
save_state SUBNET1 "${SUBNET1}"
save_state SUBNET2 "${SUBNET2}"
save_state SUBNET3 "${SUBNET3}"

# --- Security groups ---
EXISTING_TASK_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_TASK_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [[ "${EXISTING_TASK_SG}" == "None" || -z "${EXISTING_TASK_SG}" ]]; then
  TASK_SG=$(aws ec2 create-security-group \
    --group-name "${SG_TASK_NAME}" \
    --description "tc-upgrade-poc Fargate tasks" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${PROJECT}},{Key=Owner,Value=${OWNER}},{Key=KeepUntil,Value=${KEEP_UNTIL}}]" \
    --query 'GroupId' --output text)
  # Egress all (default); optional HTTP ingress for debugging
  aws ec2 authorize-security-group-ingress --group-id "${TASK_SG}" \
    --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null || true
  log "Created task SG ${TASK_SG}"
else
  TASK_SG="${EXISTING_TASK_SG}"
  log "Reusing task SG ${TASK_SG}"
fi
save_state TASK_SG "${TASK_SG}"

EXISTING_EFS_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_EFS_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [[ "${EXISTING_EFS_SG}" == "None" || -z "${EXISTING_EFS_SG}" ]]; then
  EFS_SG=$(aws ec2 create-security-group \
    --group-name "${SG_EFS_NAME}" \
    --description "tc-upgrade-poc EFS NFS" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${PROJECT}},{Key=Owner,Value=${OWNER}},{Key=KeepUntil,Value=${KEEP_UNTIL}}]" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "${EFS_SG}" \
    --protocol tcp --port 2049 --source-group "${TASK_SG}" >/dev/null
  log "Created EFS SG ${EFS_SG}"
else
  EFS_SG="${EXISTING_EFS_SG}"
  log "Reusing EFS SG ${EFS_SG}"
fi
save_state EFS_SG "${EFS_SG}"

# --- EFS ---
EXISTING_FS=$(aws efs describe-file-systems --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId" --output text 2>/dev/null || true)
if [[ -z "${EXISTING_FS}" || "${EXISTING_FS}" == "None" ]]; then
  FS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value="${EFS_NAME}" Key=Project,Value="${PROJECT}" Key=Owner,Value="${OWNER}" Key=KeepUntil,Value="${KEEP_UNTIL}" \
    --query 'FileSystemId' --output text)
  log "Created EFS ${FS_ID}; waiting available..."
  for i in $(seq 1 60); do
    LIFE=$(aws efs describe-file-systems --file-system-id "${FS_ID}" --query 'FileSystems[0].LifeCycleState' --output text)
    [[ "${LIFE}" == "available" ]] && break
    sleep 5
  done
else
  FS_ID="${EXISTING_FS}"
  log "Reusing EFS ${FS_ID}"
fi
save_state FS_ID "${FS_ID}"

# Mount targets in two AZs
for SN in "${SUBNET1}" "${SUBNET2}"; do
  MT=$(aws efs describe-mount-targets --file-system-id "${FS_ID}" \
    --query "MountTargets[?SubnetId=='${SN}'].MountTargetId" --output text 2>/dev/null || true)
  if [[ -z "${MT}" || "${MT}" == "None" ]]; then
    MT=$(aws efs create-mount-target \
      --file-system-id "${FS_ID}" \
      --subnet-id "${SN}" \
      --security-groups "${EFS_SG}" \
      --query 'MountTargetId' --output text)
    log "Created mount target ${MT} in ${SN}"
  else
    log "Reusing mount target ${MT} in ${SN}"
  fi
done
# Wait mount targets available
log "Waiting for EFS mount targets..."
for i in $(seq 1 60); do
  STATES=$(aws efs describe-mount-targets --file-system-id "${FS_ID}" --query 'MountTargets[].LifeCycleState' --output text)
  if echo "${STATES}" | tr '\t' '\n' | grep -qv available; then
    sleep 5
  else
    break
  fi
done
log "EFS mount targets ready."

# --- CloudWatch log group ---
aws logs create-log-group --log-group-name "${LOG_GROUP}" 2>/dev/null || true
aws logs tag-log-group --log-group-name "${LOG_GROUP}" \
  --tags Project="${PROJECT}",Owner="${OWNER}",KeepUntil="${KEEP_UNTIL}" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "${LOG_GROUP}" --retention-in-days 1 >/dev/null
log "Log group ${LOG_GROUP}"

# --- IAM roles ---
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

create_role_if_needed() {
  local name="$1" policy_arn="$2"
  if aws iam get-role --role-name "${name}" >/dev/null 2>&1; then
    log "Reusing IAM role ${name}"
  else
    aws iam create-role --role-name "${name}" --assume-role-policy-document "${TRUST}" \
      --tags Key=Project,Value="${PROJECT}" Key=Owner,Value="${OWNER}" Key=KeepUntil,Value="${KEEP_UNTIL}" >/dev/null
    aws iam attach-role-policy --role-name "${name}" --policy-arn "${policy_arn}"
    log "Created IAM role ${name}"
    sleep 8  # eventual consistency
  fi
  aws iam get-role --role-name "${name}" --query 'Role.Arn' --output text
}

EXEC_ROLE_ARN=$(create_role_if_needed "${EXEC_ROLE_NAME}" "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy")
# Task role: minimal — allow describing nothing special; EFS without IAM auth
if aws iam get-role --role-name "${TASK_ROLE_NAME}" >/dev/null 2>&1; then
  TASK_ROLE_ARN=$(aws iam get-role --role-name "${TASK_ROLE_NAME}" --query 'Role.Arn' --output text)
  log "Reusing IAM role ${TASK_ROLE_NAME}"
else
  aws iam create-role --role-name "${TASK_ROLE_NAME}" --assume-role-policy-document "${TRUST}" \
    --tags Key=Project,Value="${PROJECT}" Key=Owner,Value="${OWNER}" Key=KeepUntil,Value="${KEEP_UNTIL}" >/dev/null
  TASK_ROLE_ARN=$(aws iam get-role --role-name "${TASK_ROLE_NAME}" --query 'Role.Arn' --output text)
  log "Created IAM role ${TASK_ROLE_NAME}"
  sleep 8
fi
save_state EXEC_ROLE_ARN "${EXEC_ROLE_ARN}"
save_state TASK_ROLE_ARN "${TASK_ROLE_ARN}"

# --- ECR ---
if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "${ECR_REPO}" \
    --tags Key=Project,Value="${PROJECT}" Key=Owner,Value="${OWNER}" Key=KeepUntil,Value="${KEEP_UNTIL}" \
    --image-scanning-configuration scanOnPush=false >/dev/null
  log "Created ECR repo ${ECR_REPO}"
else
  log "Reusing ECR repo ${ECR_REPO}"
fi
ECR_URI="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
save_state ECR_URI "${ECR_URI}"

log "Building and pushing image..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  sudo docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
sudo docker build -t "${ECR_URI}:v1" -t "${ECR_URI}:latest" "${SCRIPT_DIR}"
sudo docker push "${ECR_URI}:v1"
sudo docker push "${ECR_URI}:latest"
log "Image pushed ${ECR_URI}:v1"

# --- ECS cluster ---
EXISTING_CLUSTER=$(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --query 'clusters[0].status' --output text 2>/dev/null || echo NONE)
if [[ "${EXISTING_CLUSTER}" != "ACTIVE" ]]; then
  aws ecs create-cluster --cluster-name "${CLUSTER_NAME}" \
    --tags key=Project,value="${PROJECT}" key=Owner,value="${OWNER}" key=KeepUntil,value="${KEEP_UNTIL}" >/dev/null
  log "Created cluster ${CLUSTER_NAME}"
else
  log "Reusing cluster ${CLUSTER_NAME}"
fi

# --- Task definition v1 ---
cat > "${SCRIPT_DIR}/taskdef-v1.json" << TDEOF
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
        {"name": "APP_VERSION", "value": "v1"},
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

TD_ARN=$(aws ecs register-task-definition --cli-input-json "file://${SCRIPT_DIR}/taskdef-v1.json" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
# Tag task definition (via resource tagging on family revision if supported — ECS tags on register)
aws ecs tag-resource --resource-arn "${TD_ARN}" \
  --tags key=Project,value="${PROJECT}" key=Owner,value="${OWNER}" key=KeepUntil,value="${KEEP_UNTIL}" 2>/dev/null || true
log "Registered task def ${TD_ARN}"
save_state TD_V1_ARN "${TD_ARN}"

# --- ECS service (stop-before-start: minHealthy=0, maxPercent=100) ---
EXISTING_SVC=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
  --query 'services[0].status' --output text 2>/dev/null || echo NONE)
if [[ "${EXISTING_SVC}" != "ACTIVE" ]]; then
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${SERVICE_NAME}" \
    --task-definition "${TD_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET1},${SUBNET2}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}" \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=100,minimumHealthyPercent=0" \
    --scheduling-strategy REPLICA \
    --tags key=Project,value="${PROJECT}" key=Owner,value="${OWNER}" key=KeepUntil,value="${KEEP_UNTIL}" \
    --enable-execute-command 2>/dev/null || \
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${SERVICE_NAME}" \
    --task-definition "${TD_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET1},${SUBNET2}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}" \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=100,minimumHealthyPercent=0" \
    --scheduling-strategy REPLICA \
    --tags key=Project,value="${PROJECT}" key=Owner,value="${OWNER}" key=KeepUntil,value="${KEEP_UNTIL}"
  log "Created service ${SERVICE_NAME}"
else
  log "Service exists; updating to v1 task def..."
  aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" \
    --task-definition "${TD_ARN}" \
    --desired-count 1 \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=100,minimumHealthyPercent=0" \
    --force-new-deployment >/dev/null
fi

wait_service_stable "${CLUSTER_NAME}" "${SERVICE_NAME}" 600

TASK_ARN=$(aws ecs list-tasks --cluster "${CLUSTER_NAME}" --service-name "${SERVICE_NAME}" \
  --desired-status RUNNING --query 'taskArns[0]' --output text)
save_state TD_V1_TASK_ARN "${TASK_ARN}"
log "v1 running task: ${TASK_ARN}"

# Capture v1 logs / marker evidence
sleep 15
aws logs filter-log-events --log-group-name "${LOG_GROUP}" --limit 50 \
  --query 'events[*].message' --output text > "${PROOF_DIR}/v1-logs.txt" 2>/dev/null || true
aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
  --query 'services[0].{deployConfig:deploymentConfiguration,running:runningCount,desired:desiredCount,taskDef:taskDefinition}' \
  --output json > "${PROOF_DIR}/v1-service.json"

log "=== Provision complete ==="
log "State file: ${STATE_FILE}"
cat "${STATE_FILE}"
