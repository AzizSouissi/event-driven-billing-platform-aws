###############################################################################
# Bootstrap — Remote State Infrastructure
# ──────────────────────────────────────────────────────────────────────────────
# Run this ONCE before any other `terraform init`.
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
#
# This creates the S3 bucket and DynamoDB table referenced by the backend
# blocks in environments/*/backend.tf.
#
# Uses LOCAL state intentionally — the backend infra cannot store its own state
# in a bucket that doesn't exist yet (chicken-and-egg).
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "Region for the state bucket and lock table"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "S3 bucket name for Terraform state"
  type        = string
  default     = "event-driven-billing-tf-state"
}

variable "lock_table_name" {
  description = "DynamoDB table name for state locking"
  type        = string
  default     = "terraform-state-lock"
}

# ---------- S3 Bucket ------------------------------------------------------ #
resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  # Prevent accidental destruction of the state bucket
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = var.state_bucket_name
    Purpose   = "terraform-state"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- DynamoDB Lock Table -------------------------------------------- #
resource "aws_dynamodb_table" "terraform_lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name      = var.lock_table_name
    Purpose   = "terraform-state-lock"
    ManagedBy = "terraform-bootstrap"
  }
}

# ---------- Outputs -------------------------------------------------------- #
output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.bucket
}

output "state_bucket_arn" {
  value = aws_s3_bucket.terraform_state.arn
}

output "lock_table_name" {
  value = aws_dynamodb_table.terraform_lock.name
}
