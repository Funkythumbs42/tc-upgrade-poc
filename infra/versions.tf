# EXAMPLE / SKETCH — do not blind-apply to production.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Intentionally no backend block — local state only for this sketch.
  # Add a remote backend before any real apply.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform-sketch"
      Warning   = "example-not-prod"
    }
  }
}
