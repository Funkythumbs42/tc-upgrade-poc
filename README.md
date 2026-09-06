# TeamCity-style ECS Fargate Upgrade POC (stop-before-start)

Tiny AWS stand-in that proves the ECS choreography used for TeamCity upgrades on Fargate:

- `deploymentConfiguration.minimumHealthyPercent=0`
- `deploymentConfiguration.maximumPercent=100`
- `desiredCount=1`
- Deployment circuit breaker + rollback enabled
- EFS volume mounted; marker written by v1, read by v2 after upgrade
- **No NAT, no ALB, no RDS** — default VPC public subnets + `assignPublicIp=ENABLED`
- Fargate `cpu=256` / `memory=512`

This is **not** a real TeamCity+RDS stack (that is not free). It exercises the same stop-before-start ECS pattern.

## Results

See **[PROOF.md](./PROOF.md)** for the 2026-09-06 end-to-end run in account `784318225077` / `eu-west-1`:

- Stop-before-start confirmed (`maxRunningSeenDuringUpgrade=1`, zero-running gap)
- EFS marker survived (`written_by=v1` found by v2)
- Teardown completed; only inactive ECS metadata ARNs remain ($0)

Raw captures live under `proof/`.

## Scripts

| Script | Purpose |
|--------|---------|
| `provision.sh` | SG, EFS, IAM, ECR, cluster, task def v1, service |
| `upgrade.sh` | Register v2 (`APP_VERSION=v2`), force deploy, poll proof |
| `teardown.sh` | Delete all POC resources |

Shared config: `config.env` (no secrets). Runtime IDs go to `.state.env` (gitignored).

## Usage

```bash
# Prerequisites: AWS CLI configured (eu-west-1), Docker (script uses sudo docker), jq
cd /workspace/tc-upgrade-poc   # or clone path
./provision.sh
./upgrade.sh
# review PROOF.md / proof/
./teardown.sh
```

Tags applied: `Project=tc-upgrade-poc`, `Owner=greg`, `KeepUntil=same-day-teardown`.

## App

`app.py` + `Dockerfile` — tiny Python HTTP server on `:8080` that writes `/data/marker.txt` once and serves `APP_VERSION` + marker contents. Health check via `wget`.

## Cost / safety

Prefer free-tier-ish: tiny Fargate, skip RDS/ALB/NAT. Tear down the same session. Do not touch unrelated resources.
