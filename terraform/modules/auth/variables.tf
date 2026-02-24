# ──────────────────────────────────────────────────────────────────────────── #
# Required Variables
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
  description = "AWS region (used for Cognito issuer URL construction)"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────── #
# User Pool Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "allow_admin_create_user_only" {
  description = "If true, only admins can create users (recommended for B2B SaaS)"
  type        = bool
  default     = true
}

variable "password_minimum_length" {
  description = "Minimum password length (NIST recommends ≥ 8, we default 12)"
  type        = number
  default     = 12
}

variable "advanced_security_mode" {
  description = "Cognito advanced security mode: OFF, AUDIT, or ENFORCED"
  type        = string
  default     = "AUDIT"

  validation {
    condition     = contains(["OFF", "AUDIT", "ENFORCED"], var.advanced_security_mode)
    error_message = "Must be OFF, AUDIT, or ENFORCED."
  }
}

variable "ses_email_identity" {
  description = "SES identity ARN for sending emails. Empty string uses Cognito default."
  type        = string
  default     = ""
}

variable "pre_token_generation_lambda_arn" {
  description = "ARN of Lambda for pre-token-generation trigger. Empty string disables."
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────── #
# Token Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "access_token_validity_minutes" {
  description = "Access token validity in minutes (default: 60)"
  type        = number
  default     = 60
}

variable "id_token_validity_minutes" {
  description = "ID token validity in minutes (default: 60)"
  type        = number
  default     = 60
}

variable "refresh_token_validity_days" {
  description = "Refresh token validity in days (default: 30)"
  type        = number
  default     = 30
}

# ──────────────────────────────────────────────────────────────────────────── #
# App Client — OAuth / Callback URLs
# ──────────────────────────────────────────────────────────────────────────── #

variable "callback_urls" {
  description = "OAuth2 callback URLs (redirect after login)"
  type        = list(string)
  default     = ["http://localhost:3000/callback"]
}

variable "logout_urls" {
  description = "OAuth2 logout URLs (redirect after logout)"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway
# ──────────────────────────────────────────────────────────────────────────── #

variable "cors_allow_origins" {
  description = "Allowed CORS origins for the HTTP API"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for API access logs"
  type        = number
  default     = 30
}
