variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for ARN construction"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for ARN construction"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "additional_secret_arns" {
  description = "Additional Secrets Manager ARNs that Lambda can read (e.g., RDS-managed secrets)"
  type        = list(string)
  default     = []
}

variable "kms_key_arns" {
  description = "KMS key ARNs that Lambda needs to decrypt (e.g., Aurora secret encryption key)"
  type        = list(string)
  default     = []
}
