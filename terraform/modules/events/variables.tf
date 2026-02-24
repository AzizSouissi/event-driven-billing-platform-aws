# ──────────────────────────────────────────────────────────────────────────── #
# Required Variables
# ──────────────────────────────────────────────────────────────────────────── #

variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────── #
# VPC References (from VPC module)
# ──────────────────────────────────────────────────────────────────────────── #

variable "private_subnet_ids" {
  description = "Private subnet IDs for Lambda VPC placement"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security group ID for Lambda functions"
  type        = string
}

# ──────────────────────────────────────────────────────────────────────────── #
# IAM References (from IAM module)
# ──────────────────────────────────────────────────────────────────────────── #

variable "lambda_execution_role_arn" {
  description = "IAM role ARN for Lambda execution"
  type        = string
}

# ──────────────────────────────────────────────────────────────────────────── #
# Database
# ──────────────────────────────────────────────────────────────────────────── #

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────── #
# Logging
# ──────────────────────────────────────────────────────────────────────────── #

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}
