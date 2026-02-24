variable "project" {
  description = "Project name"
  type        = string
  default     = "billing-platform"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "db_port" {
  description = "Database port"
  type        = number
  default     = 5432
}

# ──────────────────────────────────────────────────────────────────────────── #
# Auth / Cognito
# ──────────────────────────────────────────────────────────────────────────── #

variable "allow_admin_create_user_only" {
  description = "Only admins can create users"
  type        = bool
  default     = true
}

variable "password_minimum_length" {
  description = "Minimum password length"
  type        = number
  default     = 12
}

variable "advanced_security_mode" {
  description = "Cognito advanced security: OFF, AUDIT, ENFORCED"
  type        = string
  default     = "AUDIT"
}

variable "access_token_validity_minutes" {
  description = "Access token lifetime in minutes"
  type        = number
  default     = 60
}

variable "id_token_validity_minutes" {
  description = "ID token lifetime in minutes"
  type        = number
  default     = 60
}

variable "refresh_token_validity_days" {
  description = "Refresh token lifetime in days"
  type        = number
  default     = 30
}

variable "callback_urls" {
  description = "OAuth2 callback URLs"
  type        = list(string)
  default     = ["http://localhost:3000/callback"]
}

variable "logout_urls" {
  description = "OAuth2 logout redirect URLs"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "cors_allow_origins" {
  description = "CORS allowed origins for the HTTP API"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

# ──────────────────────────────────────────────────────────────────────────── #
# API / Routes / Throttling
# ──────────────────────────────────────────────────────────────────────────── #

variable "api_stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "v1"
}

variable "default_throttle_burst_limit" {
  description = "Default burst limit for all API routes"
  type        = number
  default     = 100
}

variable "default_throttle_rate_limit" {
  description = "Default steady-state rate limit for all API routes (req/s)"
  type        = number
  default     = 50
}

# ──────────────────────────────────────────────────────────────────────────── #
# Database — Aurora Serverless v2
# ──────────────────────────────────────────────────────────────────────────── #

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "15.4"
}

variable "aurora_database_name" {
  description = "Default database name"
  type        = string
  default     = "billing"
}

variable "aurora_master_username" {
  description = "Master username for Aurora"
  type        = string
  default     = "billing_admin"
}

variable "aurora_min_acu" {
  description = "Minimum Aurora Capacity Units (0.5 = smallest)"
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Maximum Aurora Capacity Units"
  type        = number
  default     = 4
}

variable "aurora_reader_count" {
  description = "Number of reader instances (0 for dev, ≥1 for prod HA)"
  type        = number
  default     = 0
}

variable "aurora_backup_retention_days" {
  description = "Automated backup retention period"
  type        = number
  default     = 7
}

variable "aurora_skip_final_snapshot" {
  description = "Skip final snapshot on cluster deletion (true for dev)"
  type        = bool
  default     = true
}

variable "aurora_deletion_protection" {
  description = "Prevent accidental cluster deletion (false for dev, true for prod)"
  type        = bool
  default     = false
}

# ──────────────────────────────────────────────────────────────────────────── #
# VPC Endpoints
# ──────────────────────────────────────────────────────────────────────────── #

variable "enable_vpc_interface_endpoints" {
  description = "Enable Interface VPC endpoints for SQS, Secrets Manager, KMS, Logs, SNS, SSM (Gateway endpoints for S3/DynamoDB are always on)"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────────────── #
# Observability
# ──────────────────────────────────────────────────────────────────────────── #

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications (empty = no email)"
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────── #
# WAF
# ──────────────────────────────────────────────────────────────────────────── #

variable "waf_rate_limit_threshold" {
  description = "WAF rate limit: max requests per 5-min window per IP (default: 2000 ≈ 6.7 req/s)"
  type        = number
  default     = 2000
}

variable "waf_managed_rules_action" {
  description = "WAF managed rules action: 'block' (enforce) or 'count' (monitor/evaluate)"
  type        = string
  default     = "count"
}

variable "waf_blocked_country_codes" {
  description = "ISO 3166-1 alpha-2 country codes to block (empty = no geo-blocking)"
  type        = list(string)
  default     = []
}

variable "waf_enable_logging" {
  description = "Enable WAF request logging to CloudWatch Logs"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────────────── #
# X-Ray Distributed Tracing
# ──────────────────────────────────────────────────────────────────────────── #

variable "enable_xray_tracing" {
  description = "Enable X-Ray active tracing on all Lambda functions and SNS topics"
  type        = bool
  default     = true
}
