# EXAMPLE / SKETCH — placeholders; replace before any real plan/apply.

variable "aws_region" {
  description = "AWS region for pipeline / CodeBuild / Step Functions (orchestrator region)."
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Name prefix for sketch resources."
  type        = string
  default     = "tc-upgrade-poc"
}

variable "github_connection_arn" {
  description = <<-EOT
    CodeStar Connections ARN for the GitHub (or GitHub Enterprise) connection.
    Placeholder only — create a connection in the AWS console / CLI and paste the ARN.
    Example shape: arn:aws:codestar-connections:REGION:ACCOUNT:connection/UUID
  EOT
  type        = string
  default     = "arn:aws:codestar-connections:eu-west-1:000000000000:connection/REPLACE-ME"
}

variable "github_owner" {
  description = "GitHub org or user that owns the repo."
  type        = string
  default     = "Funkythumbs42"
}

variable "github_repo" {
  description = "GitHub repository name (source for CodePipeline / CodeBuild)."
  type        = string
  default     = "tc-upgrade-poc"
}

variable "github_branch" {
  description = "Branch to build / deploy from."
  type        = string
  default     = "main"
}

variable "ecs_cluster_name" {
  description = "Target ECS cluster name (the workload being upgraded — NOT where CodeBuild runs)."
  type        = string
  default     = "tc-upgrade-poc-cluster"
}

variable "ecs_service_name" {
  description = "Target ECS service name."
  type        = string
  default     = "tc-upgrade-poc-svc"
}

variable "rds_db_instance_identifier" {
  description = "Optional RDS DB instance id to snapshot before upgrade. Empty string skips BackupRDS. Strongly recommended for major jumps."
  type        = string
  default     = ""
}

variable "approval_sns_topic_arn" {
  description = "Optional SNS topic ARN for CodePipeline manual approval notifications. Empty = no notification."
  type        = string
  default     = ""
}

variable "wait_seconds_before_drain" {
  description = "Seconds to wait after optional RDS backup before drain check (maintenance window padding)."
  type        = number
  default     = 60
}

variable "codebuild_compute_type" {
  description = "CodeBuild compute type for the upgrade runner."
  type        = string
  default     = "BUILD_GENERAL1_SMALL"
}

variable "teamcity_base_url" {
  description = "Base URL of the TeamCity server (e.g. https://teamcity.example.com). Passed to drain/confirm/poll scripts."
  type        = string
  default     = ""
}

variable "target_tc_version" {
  description = "Target TeamCity version string expected from /app/rest/server after upgrade (e.g. 2025.07.3)."
  type        = string
  default     = ""
}

variable "teamcity_log_group" {
  description = "CloudWatch Logs group for the TeamCity server container (source of Super user / maintenance token)."
  type        = string
  default     = ""
}

variable "agent_ecs_cluster_name" {
  description = "Optional ECS cluster hosting build agents; scaled to 0 during preflight drain."
  type        = string
  default     = ""
}

variable "agent_ecs_service_name" {
  description = "Optional ECS service name for build agents; desiredCount set to 0 during drain."
  type        = string
  default     = ""
}

variable "agent_asg_name" {
  description = "Optional Auto Scaling Group name for EC2 build agents; desired capacity set to 0 during drain."
  type        = string
  default     = ""
}

variable "poll_boot_timeout_sec" {
  description = "Timeout for WaitMaintenanceOrBoot (maintenance page OR version)."
  type        = number
  default     = 1800
}

variable "wait_db_timeout_sec" {
  description = "Timeout for WaitDbConversion after maintenance confirm (DB/data conversion can be long)."
  type        = number
  default     = 5400
}

variable "poll_ready_timeout_sec" {
  description = "Timeout for final PollTeamCityReady (REQUIRE_VERSION=1)."
  type        = number
  default     = 1800
}
