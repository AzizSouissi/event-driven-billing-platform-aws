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
# Database
# ──────────────────────────────────────────────────────────────────────────── #

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  type        = string
  default     = ""
}
