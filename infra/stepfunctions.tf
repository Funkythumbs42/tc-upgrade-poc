# EXAMPLE / SKETCH — Step Functions orchestrator (drain, deploy, maintenance confirm, DB wait, poll, rollback).
# Must NOT run on the TeamCity being upgraded.

resource "aws_sfn_state_machine" "upgrade" {
  name     = "${var.project_name}-upgrade"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/upgrade_asl.json.tftpl", {
    backup_project_name    = aws_codebuild_project.phase["backup"].name
    drain_project_name     = aws_codebuild_project.phase["drain"].name
    deploy_project_name    = aws_codebuild_project.phase["deploy"].name
    poll_project_name      = aws_codebuild_project.phase["poll"].name
    confirm_project_name   = aws_codebuild_project.phase["confirm"].name
    wait_db_project_name   = aws_codebuild_project.phase["wait_db"].name
    rollback_project_name  = aws_codebuild_project.phase["rollback"].name
    wait_seconds           = var.wait_seconds_before_drain
    poll_boot_timeout_sec  = var.poll_boot_timeout_sec
    wait_db_timeout_sec    = var.wait_db_timeout_sec
    poll_ready_timeout_sec = var.poll_ready_timeout_sec
  })

  # Logging OFF in the sketch so apply does not require a log-group destination.
  # Enable ERROR/ALL + log_destination before production use.
  logging_configuration {
    include_execution_data = false
    level                  = "OFF"
  }
}
