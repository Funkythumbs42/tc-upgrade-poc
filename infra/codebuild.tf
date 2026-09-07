# EXAMPLE / SKETCH — CodeBuild projects invoked by Step Functions.
# Each runs bash + AWS CLI against scripts from this git repo.
# PrivilegedMode left false (no Docker-in-Docker required for the sketch).
# IMPORTANT: these builders must NOT run on the TeamCity host being upgraded.

locals {
  # Shared buildspec: checkout is already done by CodePipeline artifact;
  # for SFN-started builds we clone via env GITHUB_* or use Source from the project.
  # Here each project uses GITHUB as source so SFN can StartBuild without a pipeline artifact.
  build_env = {
    ECS_CLUSTER  = var.ecs_cluster_name
    ECS_SERVICE  = var.ecs_service_name
    AWS_REGION   = var.aws_region
    PROJECT_NAME = var.project_name
    RDS_DB_ID    = var.rds_db_instance_identifier
  }
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${var.project_name}-upgrade"
  retention_in_days = 14
}

# Helper: one module-like inline project definition via for_each
locals {
  build_phases = {
    backup = {
      description = "Optional RDS snapshot before upgrade"
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
      description = "Pre-deploy drain / health check"
      commands = [
        "echo \"=== DrainCheck ===\"",
        "aws ecs describe-services --cluster \"$${ECS_CLUSTER}\" --services \"$${ECS_SERVICE}\" --output json | tee drain-status.json",
        "RUNNING=$$(jq -r '.services[0].runningCount // 0' drain-status.json)",
        "echo \"runningCount=$${RUNNING}\"",
        "# Sketch: assert service is stable enough to upgrade; real drain logic goes here",
      ]
    }
    deploy = {
      description = "Run upgrade.sh from this repo (stop-before-start ECS pattern)"
      commands = [
        "echo \"=== Deploy (upgrade.sh) ===\"",
        "ls -la",
        "chmod +x *.sh || true",
        "# Production: ensure .state.env / config is injected via SSM or prior provision stage",
        "# Sketch invokes upgrade.sh when state is present; otherwise dry-run describe:",
        "if [ -f .state.env ]; then ./upgrade.sh; else",
        "  echo \"No .state.env — sketch dry-run: force new deployment\"",
        "  aws ecs update-service --cluster \"$${ECS_CLUSTER}\" --service \"$${ECS_SERVICE}\" --force-new-deployment",
        "fi",
      ]
    }
    verify = {
      description = "Verify post-upgrade (running count, task def, optional marker)"
      commands = [
        "echo \"=== Verify ===\"",
        "aws ecs describe-services --cluster \"$${ECS_CLUSTER}\" --services \"$${ECS_SERVICE}\" --output json | tee verify-status.json",
        "PRIMARY=$$(jq -r '.services[0].deployments[] | select(.status==\"PRIMARY\") | .rolloutState // .runningCount' verify-status.json)",
        "echo \"primary=$${PRIMARY}\"",
        "RUNNING=$$(jq -r '.services[0].runningCount // 0' verify-status.json)",
        "DESIRED=$$(jq -r '.services[0].desiredCount // 0' verify-status.json)",
        "test \"$${RUNNING}\" = \"$${DESIRED}\" || (echo \"Verify failed: running!=desired\" && exit 1)",
      ]
    }
    rollback = {
      description = "Catch path: roll back ECS service to previous task definition"
      commands = [
        "echo \"=== Rollback ===\"",
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

resource "aws_codebuild_project" "backup" {
  name          = "${var.project_name}-backup"
  description   = local.build_phases.backup.description
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

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
          commands = local.build_phases.backup.commands
        }
      }
    })
    git_clone_depth = 1
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "backup"
    }
  }
}

resource "aws_codebuild_project" "drain" {
  name          = "${var.project_name}-drain"
  description   = local.build_phases.drain.description
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 15

  artifacts { type = "NO_ARTIFACTS" }

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
        install = { commands = ["yum install -y jq || true"] }
        build   = { commands = local.build_phases.drain.commands }
      }
    })
    git_clone_depth = 1
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "drain"
    }
  }
}

resource "aws_codebuild_project" "deploy" {
  name          = "${var.project_name}-deploy"
  description   = local.build_phases.deploy.description
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 45

  artifacts { type = "NO_ARTIFACTS" }

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
        install = { commands = ["yum install -y jq || true"] }
        build   = { commands = local.build_phases.deploy.commands }
      }
    })
    git_clone_depth = 1
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "deploy"
    }
  }
}

resource "aws_codebuild_project" "verify" {
  name          = "${var.project_name}-verify"
  description   = local.build_phases.verify.description
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts { type = "NO_ARTIFACTS" }

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
        install = { commands = ["yum install -y jq || true"] }
        build   = { commands = local.build_phases.verify.commands }
      }
    })
    git_clone_depth = 1
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "verify"
    }
  }
}

resource "aws_codebuild_project" "rollback" {
  name          = "${var.project_name}-rollback"
  description   = local.build_phases.rollback.description
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts { type = "NO_ARTIFACTS" }

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
        install = { commands = ["yum install -y jq || true"] }
        build   = { commands = local.build_phases.rollback.commands }
      }
    })
    git_clone_depth = 1
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "rollback"
    }
  }
}
