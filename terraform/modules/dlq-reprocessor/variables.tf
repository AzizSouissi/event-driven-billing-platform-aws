###############################################################################
# DLQ Reprocessor Module — Variables
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

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────── #
# IAM
# ──────────────────────────────────────────────────────────────────────────── #

variable "lambda_execution_role_arn" {
  description = "IAM role ARN for the Lambda function"
  type        = string
}

variable "lambda_execution_role_id" {
  description = "IAM role ID (name) for attaching inline policies"
  type        = string
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS References (from events module)
# ──────────────────────────────────────────────────────────────────────────── #

variable "queue_map" {
  description = "Map of consumer name → { dlq_url, target_queue_url } for the reprocessor"
  type        = map(object({
    dlq_url          = string
    target_queue_url = string
  }))
}

variable "processing_queue_arns" {
  description = "Map of consumer name → processing queue ARN (for IAM SendMessage permission)"
  type        = map(string)
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "timeout" {
  description = "Lambda timeout in seconds (needs time to drain DLQ)"
  type        = number
  default     = 300  # 5 minutes — enough for large DLQ backlogs
}

variable "memory_size" {
  description = "Lambda memory in MB"
  type        = number
  default     = 128  # Minimal — SQS I/O bound, not CPU
}

# ──────────────────────────────────────────────────────────────────────────── #
# Logging
# ──────────────────────────────────────────────────────────────────────────── #

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

# ──────────────────────────────────────────────────────────────────────────── #
# X-Ray Distributed Tracing
# ──────────────────────────────────────────────────────────────────────────── #

variable "enable_xray_tracing" {
  description = "Enable X-Ray active tracing on Lambda function"
  type        = bool
  default     = true
}