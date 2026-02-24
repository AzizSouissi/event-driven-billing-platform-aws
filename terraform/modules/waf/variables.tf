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
  description = "AWS region (used for CloudWatch alarm dimensions)"
  type        = string
}

variable "api_stage_arn" {
  description = "ARN of the API Gateway stage to protect (format: arn:aws:apigateway:{region}::/apis/{api-id}/stages/{stage-name})"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────── #
# WAF Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "rate_limit_threshold" {
  description = "Maximum requests per 5-minute window per IP before blocking (default: 2000 ≈ 6.7 req/s)"
  type        = number
  default     = 2000
}

variable "managed_rules_action" {
  description = "Action for AWS managed rule groups: 'block' (enforce) or 'count' (monitor/evaluate)"
  type        = string
  default     = "block"

  validation {
    condition     = contains(["block", "count"], var.managed_rules_action)
    error_message = "Must be 'block' or 'count'."
  }
}

variable "common_rules_excluded_rules" {
  description = "List of rule names to exclude (set to COUNT) from the Common Rule Set (e.g., SizeRestrictions_BODY for large JSON payloads)"
  type        = list(string)
  default     = ["SizeRestrictions_BODY"]
}

variable "blocked_country_codes" {
  description = "ISO 3166-1 alpha-2 country codes to block (empty list disables geo-blocking)"
  type        = list(string)
  default     = []
}

# ──────────────────────────────────────────────────────────────────────────── #
# Logging
# ──────────────────────────────────────────────────────────────────────────── #

variable "enable_logging" {
  description = "Enable WAF request logging to CloudWatch Logs"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for WAF logs"
  type        = number
  default     = 30
}

variable "redact_authorization_header" {
  description = "Redact the Authorization header from WAF logs (recommended for production)"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────────────── #
# Alarms
# ──────────────────────────────────────────────────────────────────────────── #

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for WAF alarms (empty string disables alarms)"
  type        = string
  default     = ""
}

variable "blocked_requests_alarm_threshold" {
  description = "Number of blocked requests per 5-min period to trigger alarm"
  type        = number
  default     = 100
}
