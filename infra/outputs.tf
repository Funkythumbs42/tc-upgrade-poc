# EXAMPLE / SKETCH outputs

output "codepipeline_name" {
  description = "Name of the sketch CodePipeline (start + manual approval UX)."
  value       = aws_codepipeline.upgrade.name
}

output "codepipeline_arn" {
  description = "ARN of the sketch CodePipeline."
  value       = aws_codepipeline.upgrade.arn
}

output "state_machine_arn" {
  description = "ARN of the Step Functions upgrade orchestrator."
  value       = aws_sfn_state_machine.upgrade.arn
}

output "state_machine_name" {
  description = "Name of the Step Functions state machine."
  value       = aws_sfn_state_machine.upgrade.name
}

output "artifact_bucket" {
  description = "S3 bucket used for pipeline artifacts."
  value       = aws_s3_bucket.artifacts.bucket
}

output "codebuild_projects" {
  description = "CodeBuild project names invoked by the state machine."
  value = {
    backup   = aws_codebuild_project.phase["backup"].name
    drain    = aws_codebuild_project.phase["drain"].name
    deploy   = aws_codebuild_project.phase["deploy"].name
    poll     = aws_codebuild_project.phase["poll"].name
    confirm  = aws_codebuild_project.phase["confirm"].name
    wait_db  = aws_codebuild_project.phase["wait_db"].name
    rollback = aws_codebuild_project.phase["rollback"].name
  }
}

output "codebuild_project_arns" {
  description = "CodeBuild project ARNs (wired into Step Functions IAM + ASL)."
  value = {
    backup   = aws_codebuild_project.phase["backup"].arn
    drain    = aws_codebuild_project.phase["drain"].arn
    deploy   = aws_codebuild_project.phase["deploy"].arn
    poll     = aws_codebuild_project.phase["poll"].arn
    confirm  = aws_codebuild_project.phase["confirm"].arn
    wait_db  = aws_codebuild_project.phase["wait_db"].arn
    rollback = aws_codebuild_project.phase["rollback"].arn
  }
}

output "warning" {
  description = "Reminder — sketch only."
  value       = "EXAMPLE ONLY — do not blind-apply to production. Orchestrator must not run on the TeamCity being upgraded. Major jumps need RDS snapshot + maintenance-token confirm."
}
