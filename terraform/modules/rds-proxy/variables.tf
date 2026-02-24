###############################################################################
# RDS Proxy Module — Variables
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
# Network
# ──────────────────────────────────────────────────────────────────────────── #

variable "vpc_id" {
  description = "VPC ID where the proxy will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the proxy (same as Aurora subnets)"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Lambda security group ID — proxy allows ingress from this SG"
  type        = string
}

variable "rds_security_group_id" {
  description = "RDS security group ID — proxy egresses to this SG"
  type        = string
}

variable "db_port" {
  description = "Database port"
  type        = number
  default     = 5432
}

# ──────────────────────────────────────────────────────────────────────────── #
# Aurora References
# ──────────────────────────────────────────────────────────────────────────── #

variable "cluster_identifier" {
  description = "Aurora cluster identifier to proxy connections to"
  type        = string
}

variable "db_secret_arns" {
  description = "Secrets Manager ARNs containing DB credentials (proxy authenticates with these)"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the DB secret"
  type        = string
}

# ──────────────────────────────────────────────────────────────────────────── #
# Proxy Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "require_tls" {
  description = "Require TLS for all proxy connections"
  type        = bool
  default     = true
}

variable "idle_client_timeout" {
  description = "Seconds before idle client connections are closed (default: 1800 = 30 min)"
  type        = number
  default     = 1800
}

variable "debug_logging" {
  description = "Enable detailed proxy debug logs (disable in prod for performance)"
  type        = bool
  default     = false
}

# ──────────────────────────────────────────────────────────────────────────── #
# Connection Pool Tuning
# ──────────────────────────────────────────────────────────────────────────── #

variable "max_connections_percent" {
  description = "Max percentage of Aurora max_connections the proxy can use (1-100)"
  type        = number
  default     = 100
}

variable "max_idle_connections_percent" {
  description = "Percentage of max connections kept as idle warm pool (1-100)"
  type        = number
  default     = 50
}

variable "connection_borrow_timeout" {
  description = "Seconds to wait for an available connection before failing (0-3600)"
  type        = number
  default     = 120
}

variable "init_query" {
  description = "SQL statement to run when a connection is first created (e.g., SET statement_timeout)"
  type        = string
  default     = null
}

variable "session_pinning_filters" {
  description = "Session pinning filters to reduce connection pinning"
  type        = list(string)
  default     = ["EXCLUDE_VARIABLE_SETS"]
}

# ──────────────────────────────────────────────────────────────────────────── #
# Logging
# ──────────────────────────────────────────────────────────────────────────── #

variable "log_retention_days" {
  description = "CloudWatch log retention for proxy logs"
  type        = number
  default     = 30
}
