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
    backup   = aws_codebuild_project.backup.name
    drain    = aws_codebuild_project.drain.name
    deploy   = aws_codebuild_project.deploy.name
    verify   = aws_codebuild_project.verify.name
    rollback = aws_codebuild_project.rollback.name
  }
}

output "warning" {
  description = "Reminder — sketch only."
  value       = "EXAMPLE ONLY — do not blind-apply to production. Orchestrator must not run on the TeamCity being upgraded."
}
