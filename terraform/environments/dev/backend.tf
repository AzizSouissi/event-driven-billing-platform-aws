###############################################################################
# Terraform Remote Backend — S3 + DynamoDB
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#   • S3 stores the state file with versioning and server-side encryption
#     enabled (done at bucket creation — see bootstrap/README).
#   • DynamoDB provides distributed locking via LockID to prevent concurrent
#     applies that could corrupt state.
#   • key path includes environment to allow multiple envs in the same bucket.
#   • encrypt = true ensures state-at-rest encryption (AES-256 / SSE-S3).
#
# BOOTSTRAP: The S3 bucket and DynamoDB table must exist BEFORE `terraform
# init`.  Use the bootstrap script or create them manually.  See README.md.
###############################################################################

terraform {
  required_version = ">= 1.5"

  backend "s3" {
    bucket         = "event-driven-billing-tf-state"
    key            = "environments/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
