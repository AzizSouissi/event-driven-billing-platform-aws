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

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Function References
# ──────────────────────────────────────────────────────────────────────────── #

variable "lambda_function_names" {
  description = "List of all Lambda function names (API + consumer) to monitor"
  type        = list(string)
}

variable "lambda_log_group_names" {
  description = "List of CloudWatch log group names for Lambda functions"
  type        = list(string)
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway
# ──────────────────────────────────────────────────────────────────────────── #

variable "api_id" {
  description = "HTTP API Gateway ID for metrics"
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────── #
# RDS (optional — may not exist yet)
# ──────────────────────────────────────────────────────────────────────────── #

variable "rds_instance_id" {
  description = "RDS instance identifier for monitoring (empty = skip RDS alarms)"
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS Queue Names (for dashboard)
# ──────────────────────────────────────────────────────────────────────────── #

variable "sqs_queue_names" {
  description = "List of SQS processing queue names"
  type        = list(string)
  default     = []
}

variable "dlq_names" {
  description = "List of DLQ names"
  type        = list(string)
  default     = []
}

# ──────────────────────────────────────────────────────────────────────────── #
# Alarm Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "alarm_email" {
  description = "Email address for alarm notifications (empty = no email sub)"
  type        = string
  default     = ""
}

# Lambda error rate
variable "lambda_error_rate_threshold" {
  description = "Lambda error rate threshold (%). Alarm fires when exceeded."
  type        = number
  default     = 5
}

variable "lambda_error_rate_period" {
  description = "Lambda error rate evaluation period in seconds"
  type        = number
  default     = 300
}

variable "lambda_error_rate_evaluation_periods" {
  description = "Number of consecutive periods error rate must exceed threshold"
  type        = number
  default     = 3
}

# RDS CPU
variable "rds_cpu_threshold" {
  description = "RDS CPU utilization threshold (%)"
  type        = number
  default     = 70
}

variable "rds_cpu_period" {
  description = "RDS CPU evaluation period in seconds"
  type        = number
  default     = 300
}

variable "rds_cpu_evaluation_periods" {
  description = "Number of consecutive periods CPU must exceed threshold"
  type        = number
  default     = 3
}

# RDS storage
variable "rds_free_storage_threshold_bytes" {
  description = "RDS free storage alarm threshold in bytes (default: 5 GB)"
  type        = number
  default     = 5368709120 # 5 GB
}

# RDS connections
variable "rds_max_connections_threshold" {
  description = "RDS max connections alarm threshold"
  type        = number
  default     = 80
}

# API 5xx
variable "api_5xx_threshold" {
  description = "API Gateway 5xx count threshold per period"
  type        = number
  default     = 10
}

# ──────────────────────────────────────────────────────────────────────────── #
# Anomaly Detection — API Latency
# ──────────────────────────────────────────────────────────────────────────── #

variable "anomaly_detection_band_width" {
  description = "Anomaly detection band width (standard deviations). Higher = fewer false positives, lower sensitivity."
  type        = number
  default     = 2
}

variable "anomaly_detection_period" {
  description = "Anomaly detection metric evaluation period in seconds"
  type        = number
  default     = 300
}

variable "anomaly_detection_evaluation_periods" {
  description = "Number of consecutive periods latency must exceed anomaly band"
  type        = number
  default     = 3
}
