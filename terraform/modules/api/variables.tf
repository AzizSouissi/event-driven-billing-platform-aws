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
# API Gateway References (from auth module)
# ──────────────────────────────────────────────────────────────────────────── #

variable "api_id" {
  description = "HTTP API Gateway ID (from auth module)"
  type        = string
}

variable "api_execution_arn" {
  description = "API Gateway execution ARN (for Lambda permission)"
  type        = string
}

variable "authorizer_id" {
  description = "JWT authorizer ID (from auth module)"
  type        = string
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
# Stage Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "stage_name" {
  description = "API Gateway stage name (e.g., v1, dev, prod)"
  type        = string
  default     = "v1"
}

variable "auto_deploy" {
  description = "Auto-deploy route changes to this stage"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────────────── #
# Throttling
# ──────────────────────────────────────────────────────────────────────────── #

variable "default_throttle_burst_limit" {
  description = "Default burst limit for all routes (concurrent requests)"
  type        = number
  default     = 100
}

variable "default_throttle_rate_limit" {
  description = "Default steady-state rate limit for all routes (requests/sec)"
  type        = number
  default     = 50
}

# ──────────────────────────────────────────────────────────────────────────── #
# Database Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  type        = string
  default     = ""
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic for subscription events (passed to create-subscription Lambda)"
  type        = string
  default     = ""
}

variable "rds_proxy_endpoint" {
  description = "RDS Proxy endpoint — Lambda connects here instead of directly to Aurora (empty = connect directly)"
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Functions — Route → Function mapping
# ──────────────────────────────────────────────────────────────────────────── #

variable "lambda_functions" {
  description = <<-EOT
    Map of Lambda function configurations keyed by function name.
    Each entry defines the route, runtime, handler, and throttle overrides.
  EOT

  type = map(object({
    description           = string
    route_key             = string      # e.g., "POST /v1/tenants"
    handler               = string
    runtime               = string
    timeout               = number      # seconds
    memory_size           = number      # MB
    environment_variables = map(string)
    throttle_burst_limit  = optional(number)
    throttle_rate_limit   = optional(number)
  }))
}

# ──────────────────────────────────────────────────────────────────────────── #
# Request Schemas
# ──────────────────────────────────────────────────────────────────────────── #

variable "request_schemas" {
  description = "Map of route-name → JSON Schema string for request validation"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────── #
# Logging
# ──────────────────────────────────────────────────────────────────────────── #

variable "lambda_log_retention_days" {
  description = "CloudWatch log retention for Lambda function logs"
  type        = number
  default     = 30
}

variable "api_log_retention_days" {
  description = "CloudWatch log retention for API Gateway access logs"
  type        = number
  default     = 30
}

# ──────────────────────────────────────────────────────────────────────────── #
# X-Ray Distributed Tracing
# ──────────────────────────────────────────────────────────────────────────── #

variable "enable_xray_tracing" {
  description = "Enable X-Ray active tracing on Lambda functions"
  type        = bool
  default     = true
}
