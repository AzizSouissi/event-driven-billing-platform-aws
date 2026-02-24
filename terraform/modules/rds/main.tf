###############################################################################
# RDS Module — Aurora Serverless v2 (PostgreSQL) in Private Subnets
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • AURORA SERVERLESS V2 over provisioned RDS:
#       – Auto-scales from 0.5 to 128 ACUs based on demand (no capacity planning)
#       – Pay only for capacity used — ideal for dev/staging where traffic is
#         sporadic and for prod where traffic is bursty (billing cycles)
#       – Compatible with standard PostgreSQL (no app code changes)
#       – Scales in seconds, not minutes (unlike Serverless v1)
#
#   • ENGINE: Aurora PostgreSQL 15.x — latest LTS-compatible, supports RLS,
#     JSONB, uuid-ossp, pgcrypto (all used by our schema)
#
#   • PRIVATE SUBNETS ONLY: The cluster is placed in the DB subnet group
#     (from VPC module) spanning 2 private subnets.  No public access —
#     reached only via Lambda in the same VPC through the RDS security group.
#
#   • SECRETS MANAGER INTEGRATION: Master password is managed by Secrets
#     Manager (manage_master_user_password = true).  This enables automatic
#     rotation without application changes.  Lambda reads the secret via
#     the existing DB_SECRET_ARN pattern in db.js.
#
#   • KMS ENCRYPTION: Storage encrypted at rest using a dedicated CMK.
#     Secret encrypted using the same key.  Meets SOC2/HIPAA requirements.
#
#   • MULTI-AZ:  Writer + optional reader instance.  In dev, reader_count = 0
#     (single writer only) to save cost.  In prod, reader_count ≥ 1 provides
#     HA failover and read scaling.
#
#   • DELETION PROTECTION: Enabled in prod, disabled in dev for teardown.
#
#   • BACKUP: 7-day automated backups (dev), 35-day (prod).  Point-in-time
#     recovery is always available within the retention window.
#
#   • PERFORMANCE INSIGHTS: Enabled with 7-day free-tier retention.
#     Shows top queries, wait events, and lock contention.
#
#   • ENHANCED MONITORING: 60s granularity for OS-level metrics (CPU, memory,
#     disk I/O per process).  Requires an IAM role for the monitoring agent.
#
#   • PARAMETER GROUPS: Custom cluster and instance parameter groups for:
#       – shared_preload_libraries = pg_stat_statements (query perf tracking)
#       – log_min_duration_statement = 1000 (log slow queries > 1s)
#       – rds.force_ssl = 1 (enforce TLS)
#       – Statement timeout = 30s (prevent runaway queries at DB level)
###############################################################################

# ---------- Data Sources --------------------------------------------------- #
data "aws_caller_identity" "current" {}

# ---------- KMS Key for Encryption ----------------------------------------- #
resource "aws_kms_key" "aurora" {
  description             = "KMS key for Aurora cluster encryption — ${var.project}-${var.environment}"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-aurora-kms"
  })
}

resource "aws_kms_alias" "aurora" {
  name          = "alias/${var.project}-${var.environment}-aurora"
  target_key_id = aws_kms_key.aurora.key_id
}

# ---------- Cluster Parameter Group ---------------------------------------- #
resource "aws_rds_cluster_parameter_group" "aurora" {
  name        = "${var.project}-${var.environment}-aurora-cluster-pg"
  family      = "aurora-postgresql15"
  description = "Aurora PostgreSQL 15 cluster parameters — ${var.project}-${var.environment}"

  # Enforce TLS for all connections
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Load pg_stat_statements for query performance monitoring
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # Log slow queries (> 1 second)
  parameter {
    name  = "log_min_duration_statement"
    value = var.log_min_duration_ms
  }

  # Statement timeout at DB level (safety net above application-level 8s)
  parameter {
    name  = "statement_timeout"
    value = var.db_statement_timeout_ms
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-aurora-cluster-pg"
  })
}

# ---------- Instance Parameter Group --------------------------------------- #
resource "aws_db_parameter_group" "aurora" {
  name        = "${var.project}-${var.environment}-aurora-instance-pg"
  family      = "aurora-postgresql15"
  description = "Aurora PostgreSQL 15 instance parameters — ${var.project}-${var.environment}"

  # Track pg_stat_statements per query (top 5000)
  parameter {
    name  = "pg_stat_statements.track"
    value = "all"
  }

  parameter {
    name  = "pg_stat_statements.max"
    value = "5000"
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-aurora-instance-pg"
  })
}

# ---------- Enhanced Monitoring IAM Role ----------------------------------- #
resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${var.project}-${var.environment}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRDSMonitoring"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-monitoring"
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------- Aurora Serverless v2 Cluster ----------------------------------- #
resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.project}-${var.environment}-aurora"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned" # Serverless v2 uses "provisioned" engine mode
  engine_version     = var.engine_version
  database_name      = var.database_name

  # ── Authentication ─────────────────────────────────────────────────────── #
  master_username = var.master_username

  # Let Secrets Manager generate and manage the master password automatically.
  # This creates a secret in Secrets Manager that can be rotated.
  manage_master_user_password     = true
  master_user_secret_kms_key_id   = aws_kms_key.aurora.key_id

  # ── Network ────────────────────────────────────────────────────────────── #
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.rds_security_group_id]
  port                   = var.db_port

  # ── Encryption ─────────────────────────────────────────────────────────── #
  storage_encrypted = true
  kms_key_id        = aws_kms_key.aurora.arn

  # ── Serverless v2 Scaling ──────────────────────────────────────────────── #
  serverlessv2_scaling_configuration {
    min_capacity = var.serverless_min_acu
    max_capacity = var.serverless_max_acu
  }

  # ── Backup ─────────────────────────────────────────────────────────────── #
  backup_retention_period   = var.backup_retention_days
  preferred_backup_window   = var.preferred_backup_window
  copy_tags_to_snapshot     = true
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.project}-${var.environment}-aurora-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  # ── Maintenance ────────────────────────────────────────────────────────── #
  preferred_maintenance_window = var.preferred_maintenance_window

  # ── Parameters ─────────────────────────────────────────────────────────── #
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name

  # ── Protection ─────────────────────────────────────────────────────────── #
  deletion_protection = var.deletion_protection

  # ── Logging ────────────────────────────────────────────────────────────── #
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # ── IAM Auth (future: Lambda can auth via IAM instead of password) ─────── #
  iam_database_authentication_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-aurora"
  })

  lifecycle {
    ignore_changes = [
      # Final snapshot identifier includes timestamp — ignore drift
      final_snapshot_identifier,
      # Avoid replacing cluster when AZ order changes
      availability_zones,
    ]
  }
}

# ---------- Writer Instance ------------------------------------------------ #
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.project}-${var.environment}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless" # Required for Serverless v2
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  # Instance parameters
  db_parameter_group_name = aws_db_parameter_group.aurora.name

  # Performance Insights (7-day free tier retention)
  performance_insights_enabled          = true
  performance_insights_retention_period = var.performance_insights_retention_days
  performance_insights_kms_key_id       = aws_kms_key.aurora.arn

  # Enhanced Monitoring (OS-level metrics: CPU per process, memory, disk I/O)
  monitoring_interval = var.enhanced_monitoring_interval
  monitoring_role_arn = var.enhanced_monitoring_interval > 0 ? aws_iam_role.rds_enhanced_monitoring.arn : null

  # No public access — private subnets only
  publicly_accessible = false

  # Auto minor version upgrades
  auto_minor_version_upgrade = true

  copy_tags_to_snapshot = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-aurora-writer"
  })
}

# ---------- Reader Instance(s) --------------------------------------------- #
resource "aws_rds_cluster_instance" "reader" {
  count = var.reader_count

  identifier         = "${var.project}-${var.environment}-aurora-reader-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  db_parameter_group_name = aws_db_parameter_group.aurora.name

  performance_insights_enabled          = true
  performance_insights_retention_period = var.performance_insights_retention_days
  performance_insights_kms_key_id       = aws_kms_key.aurora.arn

  monitoring_interval = var.enhanced_monitoring_interval
  monitoring_role_arn = var.enhanced_monitoring_interval > 0 ? aws_iam_role.rds_enhanced_monitoring.arn : null

  publicly_accessible        = false
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  # Promotion tier — lower number = higher priority for failover
  promotion_tier = count.index + 1

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-aurora-reader-${count.index + 1}"
  })

  depends_on = [aws_rds_cluster_instance.writer]
}

# ---------- CloudWatch Log Group for PostgreSQL Logs ----------------------- #
# Aurora exports logs to /aws/rds/cluster/<cluster-id>/postgresql
# We manage the log group explicitly to control retention.
resource "aws_cloudwatch_log_group" "aurora_postgresql" {
  name              = "/aws/rds/cluster/${aws_rds_cluster.aurora.cluster_identifier}/postgresql"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-aurora-pg-logs"
  })
}
