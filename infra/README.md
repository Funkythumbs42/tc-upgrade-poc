# Production orchestration sketch (EXAMPLE ONLY)

**Do not `terraform apply` this against production without review.**

This directory is a **sketch** of how a real TeamCity (or similar) ECS upgrade
could be orchestrated outside the instance being upgraded:

| Piece | Role |
|-------|------|
| **CodePipeline** | Start + manual approval UX |
| **Step Functions** | Orchestrator (backup → drain builds/agents → deploy → maintenance confirm → DB wait → poll → rollback) |
| **CodeBuild** | Runs scripts from this git repo (`scripts/*.sh`, `upgrade.sh`) |

The pipeline / state machine / CodeBuild project must run in a **separate**
account or at least on infrastructure that is **not** the TeamCity being
upgraded (so a failed upgrade cannot strand the orchestrator).

## What is sketched

- Variables: region, CodeStar Connections ARN (placeholder), ECS cluster/service, optional RDS id, TeamCity URL/version/log group, agent ECS/ASG for drain
- Least-privilege **IAM role sketches** for Pipeline, CodeBuild, Step Functions (includes `logs:FilterLogEvents` for maintenance token + agent scale-in)
- CodeBuild projects (Amazon Linux) via `for_each`: `backup`, `drain`, `deploy`, `poll`, `confirm`, `wait-db`, `rollback`
- Step Functions ASL (`upgrade_asl.json.tftpl`):
  `BackupRDS` → `Wait` → `DrainBuildsAndAgents` → `Deploy` → `WaitMaintenanceOrBoot` → `ConfirmMaintenanceUpgrade` → `WaitDbConversion` → `PollTeamCityReady` → Succeed; Catch → Rollback (task-def; RDS restore manual)
- CodePipeline: Source (CodeStar Connections) → Manual approval → Start execution of the state machine
- Outputs: pipeline name, state machine ARN, CodeBuild names/ARNs

## How to use (local review only)

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # fill placeholders; do not commit secrets
terraform init
terraform validate                             # after init; fmt recommended
terraform plan                                 # optional; requires real AWS creds + connection ARN
# terraform apply  — NOT recommended until roles/ARNs are reviewed for your account
```

Placeholders (e.g. `arn:aws:codestar-connections:...:connection/REPLACE-ME`) will
fail plan/apply until replaced with real values from your account.

See the root [README](../README.md) section **Major version jump (.2 → .3)** for JetBrains maintenance-token facts and dry-run guidance.
