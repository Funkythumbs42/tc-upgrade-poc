# EXAMPLE / SKETCH — CodeBuild projects invoked by Step Functions.
# Each runs bash + AWS CLI against scripts from this git repo.
# PrivilegedMode left false (no Docker-in-Docker required for the sketch).
# IMPORTANT: these builders must NOT run on the TeamCity host being upgraded.

locals {
  build_env = {
    ECS_CLUSTER       = var.ecs_cluster_name
    ECS_SERVICE       = var.ecs_service_name
    AWS_REGION        = var.aws_region
    PROJECT_NAME      = var.project_name
    RDS_DB_ID         = var.rds_db_instance_identifier
    TEAMCITY_BASE_URL = var.teamcity_base_url
    TARGET_TC_VERSION = var.target_tc_version
    LOG_GROUP         = var.teamcity_log_group
    AGENT_ECS_CLUSTER = var.agent_ecs_cluster_name
    AGENT_ECS_SERVICE = var.agent_ecs_service_name
    AGENT_ASG_NAME    = var.agent_asg_name
  }
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${var.project_name}-upgrade"
  retention_in_days = 14
}

locals {
  build_phases = {
    backup = {
      description = "Optional RDS snapshot before upgrade"
      timeout     = 30
      commands = [
        "echo \"=== BackupRDS (skippable) ===\"",
        "if [ -z \"$${RDS_DB_ID}\" ]; then echo \"RDS_DB_ID empty — skip\"; exit 0; fi",
        "SNAP=\"$${PROJECT_NAME}-pre-upgrade-$$(date -u +%Y%m%d%H%M%S)\"",
        "aws rds create-db-snapshot --db-instance-identifier \"$${RDS_DB_ID}\" --db-snapshot-identifier \"$${SNAP}\"",
        "aws rds wait db-snapshot-available --db-snapshot-identifier \"$${SNAP}\" || true",
        "echo \"SNAPSHOT_ID=$${SNAP}\"",
      ]
    }
    drain = {
      description = "Preflight: drain running builds + disable/scale-in agents (scripts/drain-builds-and-agents.sh)"
      timeout     = 45
      commands = [
        "echo \"=== DrainBuildsAndAgents ===\"",
        "chmod +x scripts/*.sh || true",
        "if [ -z \"$${TEAMCITY_BASE_URL}\" ]; then",
        "  echo \"TEAMCITY_BASE_URL empty — sketch fallback: ECS describe only\"",
        "  aws ecs describe-services --cluster \"$${ECS_CLUSTER}\" --services \"$${ECS_SERVICE}\" --output json | tee drain-status.json",
        "  exit 0",
        "fi",
        "# Inject TEAMCITY_BEARER_TOKEN from SSM/Secrets Manager in real envs (never commit)",
        "./scripts/drain-builds-and-agents.sh",
      ]
    }
    deploy = {
      description = "Run upgrade.sh from this repo (stop-before-start ECS pattern)"
      timeout     = 45
      commands = [
        "echo \"=== Deploy (upgrade.sh) ===\"",
        "ls -la",
        "chmod +x *.sh scripts/*.sh || true",
        "if [ -f .state.env ]; then ./upgrade.sh; else",
        "  echo \"No .state.env — sketch dry-run: force new deployment\"",
        "  aws ecs update-service --cluster \"$${ECS_CLUSTER}\" --service \"$${ECS_SERVICE}\" --force-new-deployment",
        "fi",
      ]
    }
    poll = {
      description = "Poll TC ready or maintenance (scripts/poll-tc-ready.sh); env overrides ACCEPT_MAINTENANCE/REQUIRE_VERSION"
      timeout     = 60
      commands = [
        "echo \"=== PollTeamCity (poll-tc-ready.sh) ===\"",
        "chmod +x scripts/*.sh || true",
        "test -n \"$${TEAMCITY_BASE_URL}\" || (echo \"TEAMCITY_BASE_URL required\" && exit 1)",
        "test -n \"$${TARGET_TC_VERSION}\" || (echo \"TARGET_TC_VERSION required\" && exit 1)",
        "./scripts/poll-tc-ready.sh",
      ]
    }
    confirm = {
      description = "Confirm maintenance upgrade via log token + HTTP POST (scripts/confirm-tc-maintenance-upgrade.sh)"
      timeout     = 60
      commands = [
        "echo \"=== ConfirmMaintenanceUpgrade ===\"",
        "chmod +x scripts/*.sh || true",
        "test -n \"$${TEAMCITY_BASE_URL}\" || (echo \"TEAMCITY_BASE_URL required\" && exit 1)",
        "./scripts/confirm-tc-maintenance-upgrade.sh",
      ]
    }
    wait_db = {
      description = "Wait for DB/data conversion after confirm (scripts/wait-db-upgrade.sh); long timeout"
      timeout     = 150
      commands = [
        "echo \"=== WaitDbConversion ===\"",
        "chmod +x scripts/*.sh || true",
        "test -n \"$${TEAMCITY_BASE_URL}\" || (echo \"TEAMCITY_BASE_URL required\" && exit 1)",
        "test -n \"$${TARGET_TC_VERSION}\" || (echo \"TARGET_TC_VERSION required\" && exit 1)",
        "./scripts/wait-db-upgrade.sh",
      ]
    }
    rollback = {
      description = "Catch path: roll back ECS service to previous task definition (RDS restore is separate/manual)"
      timeout     = 30
      commands = [
        "echo \"=== Rollback (task-def only) ===\"",
        "echo \"NOTE: After DB conversion, restore RDS/EFS from pre-upgrade snapshot manually if needed.\"",
        "PREV=\"$${PREVIOUS_TASK_DEFINITION_ARN:-}\"",
        "if [ -z \"$${PREV}\" ]; then",
        "  echo \"No PREVIOUS_TASK_DEFINITION_ARN — attempt circuit-breaker / describe only\"",
        "  aws ecs describe-services --cluster \"$${ECS_CLUSTER}\" --services \"$${ECS_SERVICE}\"",
        "  exit 0",
        "fi",
        "aws ecs update-service --cluster \"$${ECS_CLUSTER}\" --service \"$${ECS_SERVICE}\" --task-definition \"$${PREV}\"",
        "aws ecs wait services-stable --cluster \"$${ECS_CLUSTER}\" --services \"$${ECS_SERVICE}\" || true",
      ]
    }
  }
}

# Shared project factory via for_each
resource "aws_codebuild_project" "phase" {
  for_each = local.build_phases

  name          = "${var.project_name}-${each.key == "wait_db" ? "wait-db" : each.key}"
  description   = each.value.description
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = each.value.timeout

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = var.codebuild_compute_type
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false

    dynamic "environment_variable" {
      for_each = local.build_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  source {
    type     = "GITHUB"
    location = "https://github.com/${var.github_owner}/${var.github_repo}.git"
    buildspec = yamlencode({
      version = "0.2"
      phases = {
        install = {
          commands = [
            "yum install -y jq || true",
          ]
        }
        build = {
          commands = each.value.commands
        }
      }
    })
    git_clone_depth = 1
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = each.key
    }
  }
}

# Convenience aliases matching previous resource names (and ASL wiring)
locals {
  codebuild_backup   = aws_codebuild_project.phase["backup"]
  codebuild_drain    = aws_codebuild_project.phase["drain"]
  codebuild_deploy   = aws_codebuild_project.phase["deploy"]
  codebuild_poll     = aws_codebuild_project.phase["poll"]
  codebuild_confirm  = aws_codebuild_project.phase["confirm"]
  codebuild_wait_db  = aws_codebuild_project.phase["wait_db"]
  codebuild_rollback = aws_codebuild_project.phase["rollback"]
}
