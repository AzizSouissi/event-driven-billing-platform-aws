###############################################################################
# VPC Endpoints Module — Variables
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# Required
# ──────────────────────────────────────────────────────────────────────────── #

variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for endpoint service names"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────── #
# Network References (from VPC module)
# ──────────────────────────────────────────────────────────────────────────── #

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block (for security group rules)"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Interface endpoint ENI placement"
  type        = list(string)
}

variable "private_route_table_ids" {
  description = "Private route table IDs for Gateway endpoint route injection"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Lambda security group ID (allowed to reach endpoints)"
  type        = string
}

# ──────────────────────────────────────────────────────────────────────────── #
# Gateway Endpoints (Free — always recommended)
# ──────────────────────────────────────────────────────────────────────────── #

variable "enable_s3_endpoint" {
  description = "Create S3 Gateway endpoint (free, reduces NAT traffic)"
  type        = bool
  default     = true
}

variable "enable_dynamodb_endpoint" {
  description = "Create DynamoDB Gateway endpoint (free, reduces NAT traffic)"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────────────── #
# Interface Endpoints (PrivateLink — $0.01/hr per AZ + $0.01/GB)
# ──────────────────────────────────────────────────────────────────────────── #

variable "enable_interface_endpoints" {
  description = "Master toggle for Interface endpoints (also creates the shared security group)"
  type        = bool
  default     = true
}

variable "enable_sqs_endpoint" {
  description = "Create SQS Interface endpoint"
  type        = bool
  default     = true
}

variable "enable_secretsmanager_endpoint" {
  description = "Create Secrets Manager Interface endpoint"
  type        = bool
  default     = true
}

variable "enable_kms_endpoint" {
  description = "Create KMS Interface endpoint"
  type        = bool
  default     = true
}

variable "enable_logs_endpoint" {
  description = "Create CloudWatch Logs Interface endpoint"
  type        = bool
  default     = true
}

variable "enable_sns_endpoint" {
  description = "Create SNS Interface endpoint"
  type        = bool
  default     = true
}

variable "enable_ssm_endpoint" {
  description = "Create SSM Parameter Store Interface endpoint"
  type        = bool
  default     = true
}
