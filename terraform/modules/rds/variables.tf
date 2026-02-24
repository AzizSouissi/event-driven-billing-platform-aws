###############################################################################
# RDS Module — Variables
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
# Network (from VPC module)
# ──────────────────────────────────────────────────────────────────────────── #

variable "db_subnet_group_name" {
  description = "Name of the DB subnet group (from VPC module)"
  type        = string
}

variable "rds_security_group_id" {
  description = "Security group ID for RDS (from VPC module)"
  type        = string
}

variable "db_port" {
  description = "Database port"
  type        = number
  default     = 5432
}

# ──────────────────────────────────────────────────────────────────────────── #
# Engine Configuration
# ──────────────────────────────────────────────────────────────────────────── #

variable "engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "15.4"
}

variable "database_name" {
  description = "Name of the default database to create"
  type        = string
  default     = "billing"
}

variable "master_username" {
  description = "Master username for the database"
  type        = string
  default     = "billing_admin"
}

# ──────────────────────────────────────────────────────────────────────────── #
# Serverless v2 Scaling
# ──────────────────────────────────────────────────────────────────────────── #

variable "serverless_min_acu" {
  description = "Minimum Aurora Capacity Units (0.5 = smallest, good for dev)"
  type        = number
  default     = 0.5
}

variable "serverless_max_acu" {
  description = "Maximum Aurora Capacity Units (scales up under load)"
  type        = number
  default     = 4
}

# ──────────────────────────────────────────────────────────────────────────── #
# Instance Topology
# ──────────────────────────────────────────────────────────────────────────── #

variable "reader_count" {
  description = "Number of reader instances (0 in dev, ≥1 in prod for HA)"
  type        = number
  default     = 0
}

# ──────────────────────────────────────────────────────────────────────────── #
# Backup & Maintenance
# ──────────────────────────────────────────────────────────────────────────── #

variable "backup_retention_days" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Preferred UTC time window for automated backups"
  type        = string
  default     = "03:00-04:00"
}

variable "preferred_maintenance_window" {
  description = "Preferred UTC time window for maintenance"
  type        = string
  default     = "sun:05:00-sun:06:00"
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on deletion (true for dev, false for prod)"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection (false for dev, true for prod)"
  type        = bool
  default     = false
}

# ──────────────────────────────────────────────────────────────────────────── #
# Monitoring
# ──────────────────────────────────────────────────────────────────────────── #

variable "performance_insights_retention_days" {
  description = "Performance Insights retention (7 = free tier, 731 = 2 years)"
  type        = number
  default     = 7
}

variable "enhanced_monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (0 to disable, 1/5/10/15/30/60)"
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "CloudWatch log retention for PostgreSQL logs"
  type        = number
  default     = 30
}

# ──────────────────────────────────────────────────────────────────────────── #
# Parameter Tuning
# ──────────────────────────────────────────────────────────────────────────── #

variable "log_min_duration_ms" {
  description = "Log queries slower than this (ms). 1000 = log queries > 1s"
  type        = string
  default     = "1000"
}

variable "db_statement_timeout_ms" {
  description = "DB-level statement timeout (ms). Safety net above app-level 8s"
  type        = string
  default     = "30000"
}

# ──────────────────────────────────────────────────────────────────────────── #
# Encryption
# ──────────────────────────────────────────────────────────────────────────── #

variable "kms_deletion_window_days" {
  description = "KMS key deletion window in days"
  type        = number
  default     = 7
}
