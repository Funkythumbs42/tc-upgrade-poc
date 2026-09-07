# EXAMPLE / SKETCH — Step Functions orchestrator (waits, deploy, verify, rollback).
# Must NOT run on the TeamCity being upgraded.

resource "aws_sfn_state_machine" "upgrade" {
  name     = "${var.project_name}-upgrade"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/upgrade_asl.json.tftpl", {
    backup_project_name   = aws_codebuild_project.backup.name
    drain_project_name    = aws_codebuild_project.drain.name
    deploy_project_name   = aws_codebuild_project.deploy.name
    verify_project_name   = aws_codebuild_project.verify.name
    rollback_project_name = aws_codebuild_project.rollback.name
    wait_seconds          = var.wait_seconds_before_drain
  })

  # Logging OFF in the sketch so apply does not require a log-group destination.
  # Enable ERROR/ALL + log_destination before production use.
  logging_configuration {
    include_execution_data = false
    level                  = "OFF"
  }
}
