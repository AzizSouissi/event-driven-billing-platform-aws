variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "lambda_execution_role_arn" {
  description = "IAM role ARN for the Lambda function"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for VPC Lambda placement"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security group ID for Lambda VPC access"
  type        = string
}

variable "db_secret_arn" {
  description = "Secrets Manager ARN for database credentials"
  type        = string
}

variable "user_pool_arn" {
  description = "Cognito User Pool ARN (for Lambda invoke permission). Empty string skips the permission resource (create it externally to break circular deps)."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
