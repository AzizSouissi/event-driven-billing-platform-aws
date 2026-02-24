###############################################################################
# RDS Module — Outputs
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# Cluster Endpoints
# ──────────────────────────────────────────────────────────────────────────── #

output "cluster_endpoint" {
  description = "Writer endpoint (read/write) — use for all mutations"
  value       = aws_rds_cluster.aurora.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint (read-only, load-balanced across readers)"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "cluster_port" {
  description = "Database port"
  value       = aws_rds_cluster.aurora.port
}

# ──────────────────────────────────────────────────────────────────────────── #
# Cluster Identity
# ──────────────────────────────────────────────────────────────────────────── #

output "cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.aurora.cluster_identifier
}

output "cluster_arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.aurora.arn
}

output "cluster_resource_id" {
  description = "Aurora cluster resource ID (for IAM DB authentication)"
  value       = aws_rds_cluster.aurora.cluster_resource_id
}

# ──────────────────────────────────────────────────────────────────────────── #
# Database
# ──────────────────────────────────────────────────────────────────────────── #

output "database_name" {
  description = "Name of the default database"
  value       = aws_rds_cluster.aurora.database_name
}

output "master_username" {
  description = "Master username"
  value       = aws_rds_cluster.aurora.master_username
}

# ──────────────────────────────────────────────────────────────────────────── #
# Secrets Manager
# ──────────────────────────────────────────────────────────────────────────── #

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the master password"
  value       = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# Instance Identifiers (for CloudWatch monitoring)
# ──────────────────────────────────────────────────────────────────────────── #

output "writer_instance_id" {
  description = "Writer instance identifier (for CloudWatch alarms)"
  value       = aws_rds_cluster_instance.writer.identifier
}

output "reader_instance_ids" {
  description = "Reader instance identifiers"
  value       = aws_rds_cluster_instance.reader[*].identifier
}

# ──────────────────────────────────────────────────────────────────────────── #
# Encryption
# ──────────────────────────────────────────────────────────────────────────── #

output "kms_key_arn" {
  description = "KMS key ARN used for storage and secret encryption"
  value       = aws_kms_key.aurora.arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# Monitoring
# ──────────────────────────────────────────────────────────────────────────── #

output "monitoring_role_arn" {
  description = "IAM role ARN for Enhanced Monitoring"
  value       = aws_iam_role.rds_enhanced_monitoring.arn
}

output "postgresql_log_group_name" {
  description = "CloudWatch log group for Aurora PostgreSQL logs"
  value       = aws_cloudwatch_log_group.aurora_postgresql.name
}
