# PROOF: TeamCity-style ECS Fargate stop-before-start POC

**Account:** 784318225077 (user Greg)
**Region:** eu-west-1
**Date:** 2026-09-06 (same-day teardown)
**Tags:** `Project=tc-upgrade-poc`, `Owner=greg`, `KeepUntil=same-day-teardown`

## What was proven

1. **Deployment config** on service `tc-upgrade-poc-svc`:
   - `minimumHealthyPercent=0`
   - `maximumPercent=100`
   - `desiredCount=1`
   - Circuit breaker **enabled** with **rollback**

2. **Stop-before-start:** during upgrade, RUNNING task count never exceeded **1**. There was a clear gap with **0 RUNNING** tasks before the v2 task started (5 consecutive polls ~21:02:50–21:03:43 UTC / 22:02–22:03 BST).

3. **EFS persistence:** v1 wrote `/data/marker.txt`; after stop/start, v2 logged `FOUND_MARKER ... written_by=v1`.

## Timeline (UTC and BST = UTC+1)

| Event | UTC | BST | RUNNING |
|-------|-----|-----|---------|
| Pre-upgrade (v1 task `4573f4ac…`) | 21:02:15 | 22:02:15 BST | 1 |
| `update-service --force-new-deployment` | 21:02:22 | 22:02:22 BST | 1 |
| Old task draining / zero window | 21:02:50–21:03:43 | 22:02:50–22:03:43 BST | **0** |
| New v2 task `0e05c8e4…` RUNNING | 21:03:57 | 22:03:57 BST | 1 |
| Service stable on task def `:2` | 21:05:44 | 22:05:44 BST | 1 |

**maxRunningSeenDuringUpgrade = 1** → stop-before-start **OK** (never two RUNNING tasks).

## Task ARNs

| Role | Value |
|------|-------|
| v1 (stopped) | `…/task/tc-upgrade-poc-cluster/4573f4ac370d41f8a497f1fa0badde0b` |
| v2 (after upgrade) | `…/task/tc-upgrade-poc-cluster/0e05c8e4d01d4b64a281e0fabbecbb44` |
| Task def v1 | `tc-upgrade-poc-task:1` (`APP_VERSION=v1`) |
| Task def v2 | `tc-upgrade-poc-task:2` (`APP_VERSION=v2`) |

### Old task final status

- `lastStatus`: STOPPED
- `stoppedAt`: 2026-09-06T21:03:45Z (22:03:45 BST)
- `stopCode`: ServiceSchedulerInitiated
- `stoppedReason`: Scaling activity initiated by deployment

### New task

- `lastStatus`: RUNNING
- `startedAt`: 2026-09-06T21:04:12Z (22:04:12 BST)
- `taskDefinition`: `tc-upgrade-poc-task:2`

Note: old task stopped at 21:03:45Z; new task started at 21:04:12Z — no overlap.

## EFS marker evidence (CloudWatch)

- v1: `WROTE_MARKER version=v1 path=/data/marker.txt`
- v2: `FOUND_MARKER version=v2 content='written_by=v1\nts=2026-09-06T21:01:33Z'`

Interpretation: v1 created the marker on EFS; v2 mounted the same filesystem and read the v1 content — persistence across stop/start.

## Upgrade summary

See `proof/upgrade-summary.json`:

- `stopBeforeStartOk`: true
- `oldTaskStopped`: true
- `maxRunningSeenDuringUpgrade`: 1
- `pollsWithZeroRunning`: 5

## Resources created (torn down same session)

- ECS cluster `tc-upgrade-poc-cluster`
- ECS service `tc-upgrade-poc-svc` (Fargate cpu=256 memory=512, public IP, no ALB, no NAT)
- Task defs `tc-upgrade-poc-task:1` and `:2`
- EFS `tc-upgrade-poc-efs` + 2 mount targets
- SGs `tc-upgrade-poc-task-sg`, `tc-upgrade-poc-efs-sg`
- IAM roles `tc-upgrade-poc-ecsTaskExecutionRole`, `tc-upgrade-poc-ecsTaskRole`
- CW log group `/ecs/tc-upgrade-poc`
- ECR repo `tc-upgrade-poc`

**Skipped:** RDS, ALB, NAT gateway, second TeamCity.

## Cost note (approximate)

Short-lived same-session POC only. Fargate 0.25 vCPU / 0.5 GB for ~15 minutes, tiny EFS marker, small ECR image, CW logs with 1-day retention. No NAT (~$32/mo), no ALB, no RDS. Expect well under **$1** if torn down immediately.

## Proof artifacts

Directory `proof/`: `upgrade-timeline.jsonl`, `upgrade-summary.json`, `marker-logs.json`, service events, task describes, provision/upgrade/teardown logs.

## Teardown

See `proof/teardown-verify.json` and `proof/leftover-tagged.json` after `./teardown.sh`.

## Teardown results (2026-09-06 ~22:09 BST)

Live/billable resources removed:

| Resource | Result |
|----------|--------|
| ECS service | INACTIVE (scaled to 0, force-deleted) |
| ECS cluster | INACTIVE (deleted) |
| EFS + mount targets | deleted |
| Task SG / EFS SG | deleted |
| IAM roles | deleted |
| CloudWatch log group | deleted |
| ECR repository | deleted (images purged) |
| Task definitions | deregistered → status INACTIVE |

### Targeted verify (`proof/teardown-verify.json`)

```json
{
  "cluster": "INACTIVE",
  "efs": [],
  "ecr": null,
  "logGroup": null,
  "taskSg": [],
  "efsSg": [],
  "execRole": null,
  "taskRole": null
}
```

### Residual tagged ARNs (AWS keeps inactive ECS metadata; **$0**)

- `task-definition/tc-upgrade-poc-task:1` (INACTIVE)
- `task-definition/tc-upgrade-poc-task:2` (INACTIVE)
- `service/…/tc-upgrade-poc-svc` (INACTIVE)
- `cluster/tc-upgrade-poc-cluster` (INACTIVE)

No EFS, SG, IAM, ECR, or log group leftovers. No orphaned ENIs expected after SG delete succeeded.
