# EXAMPLE / SKETCH — CodePipeline = start + manual approval UX → invoke Step Functions.
# Source uses CodeStar Connections (placeholder ARN in variables).

resource "aws_codepipeline" "upgrade" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "GitHub_Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceOutput"]

      configuration = {
        ConnectionArn    = var.github_connection_arn
        FullRepositoryId = "${var.github_owner}/${var.github_repo}"
        BranchName       = var.github_branch
        # DetectChanges true so pushes can start the pipeline; approval still gates deploy.
        DetectChanges = true
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = merge(
        {
          CustomData = "Approve TeamCity-style ECS upgrade for cluster ${var.ecs_cluster_name} / service ${var.ecs_service_name}. Orchestration runs in Step Functions + CodeBuild (NOT on the TC host)."
        },
        var.approval_sns_topic_arn != "" ? { NotificationArn = var.approval_sns_topic_arn } : {}
      )
    }
  }

  stage {
    name = "Orchestrate"

    action {
      name     = "StartUpgradeStateMachine"
      category = "Invoke"
      owner    = "AWS"
      provider = "StepFunctions"
      version  = "1"

      input_artifacts = ["SourceOutput"]

      configuration = {
        StateMachineArn = aws_sfn_state_machine.upgrade.arn
        # Execution input passed into ASL Choice / Rollback env overrides.
        Input = jsonencode({
          rdsDbInstanceIdentifier   = var.rds_db_instance_identifier
          skipRdsBackup             = var.rds_db_instance_identifier == ""
          previousTaskDefinitionArn = "" # set by operator / prior stage in a fuller design
          ecsClusterName            = var.ecs_cluster_name
          ecsServiceName            = var.ecs_service_name
        })
      }
    }
  }

  # Sketch tags via provider default_tags
}
