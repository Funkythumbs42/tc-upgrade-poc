# Production orchestration sketch (EXAMPLE ONLY)

**Do not `terraform apply` this against production without review.**

This directory is a **sketch** of how a real TeamCity (or similar) ECS upgrade
could be orchestrated outside the instance being upgraded:

| Piece | Role |
|-------|------|
| **CodePipeline** | Start + manual approval UX |
| **Step Functions** | Orchestrator (waits, deploy, verify, rollback) |
| **CodeBuild** | Runs upgrade scripts from this git repo (`upgrade.sh`, etc.) |

The pipeline / state machine / CodeBuild project must run in a **separate**
account or at least on infrastructure that is **not** the TeamCity being
upgraded (so a failed upgrade cannot strand the orchestrator).

## What is sketched

- Variables: region, CodeStar Connections ARN (placeholder), ECS cluster/service, optional RDS id
- Least-privilege **IAM role sketches** for Pipeline, CodeBuild, Step Functions
- CodeBuild project (Amazon Linux) that checks out this repo and runs bash + AWS CLI
- Step Functions ASL (`upgrade_asl.json.tftpl`): BackupRDS (skippable) → Wait → DrainCheck → Deploy → Verify → Catch Rollback
- CodePipeline: Source (CodeStar Connections) → Manual approval → Start execution of the state machine
- Outputs: pipeline name, state machine ARN

## How to use (local review only)

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # fill placeholders; do not commit secrets
terraform init
terraform plan                                 # optional; requires real AWS creds + connection ARN
# terraform apply  — NOT recommended until roles/ARNs are reviewed for your account
```

Placeholders (e.g. `arn:aws:codestar-connections:...:connection/REPLACE-ME`) will
fail plan/apply until replaced with real values from your account.
