###############################################################################
# RDS Proxy Module — Connection Pooling for Lambda → Aurora
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • WHY RDS PROXY: Lambda can scale to hundreds of concurrent containers,
#     each maintaining its own database connection pool.  With max = 2 per
#     container and 200 containers, that's 400 connections — exceeding most
#     Aurora Serverless v2 limits.  RDS Proxy multiplexes these into a
#     smaller set of persistent connections, reducing:
#       – Connection storm on cold-start bursts
#       – DB memory pressure from idle connections
#       – Failover time (proxy pins connections, not the app)
#
#   • SECRETS MANAGER AUTH: The proxy authenticates to Aurora using the
#     same master secret that Lambda uses.  An IAM role grants the proxy
#     permission to read the secret.  Lambda still sends username/password
#     to the proxy — IAM DB auth is a future enhancement.
#
#   • CONNECTION BORROWING: `max_connections_percent` controls what fraction
#     of the Aurora max_connections the proxy can use.  Default 100% for dev
#     (only consumer).  In prod with multiple proxies, reduce to avoid
#     contention.
#
#   • IDLE TIMEOUT: `idle_client_timeout` = 1800s (30 min).  Lambda
#     containers that idle beyond this get their proxy connection closed.
#     Matches Lambda's freeze/thaw lifecycle.
#
#   • NETWORK: Deployed in the same private subnets as Aurora.  Lambda's
#     security group must allow egress to the proxy (same port as Aurora).
#     The proxy's security group allows ingress from Lambda SG and allows
#     egress to the RDS SG.
#
#   • TLS: Enforced (require_tls = true).  All Lambda → Proxy and
#     Proxy → Aurora connections are encrypted in transit.
#
#   • NO CODE CHANGES NEEDED in db.js:  Lambda reads host from Secrets
#     Manager.  The env var RDS_PROXY_ENDPOINT overrides `creds.host`,
#     transparently routing through the proxy.
###############################################################################

# ---------- Data Sources --------------------------------------------------- #
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------- IAM Role — RDS Proxy Secrets Manager Access -------------------- #
# The proxy needs its own IAM role to read credentials from Secrets Manager.

resource "aws_iam_role" "rds_proxy" {
  name = "${var.project}-${var.environment}-rds-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRDSProxyAssume"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-proxy"
  })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "${var.project}-${var.environment}-rds-proxy-secrets"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = var.db_secret_arns
      },
      {
        Sid    = "AllowKMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

# ---------- Security Group — RDS Proxy ------------------------------------- #
# Proxy sits between Lambda and Aurora.  Ingress from Lambda SG,
# egress to RDS SG on the DB port.

resource "aws_security_group" "rds_proxy" {
  name        = "${var.project}-${var.environment}-rds-proxy"
  description = "Security group for RDS Proxy — allows Lambda ingress and RDS egress"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-proxy"
  })
}

# Ingress: Allow Lambda → Proxy on the DB port
resource "aws_vpc_security_group_ingress_rule" "proxy_from_lambda" {
  security_group_id = aws_security_group.rds_proxy.id
  description       = "Allow Lambda to connect to RDS Proxy"

  referenced_security_group_id = var.lambda_security_group_id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-proxy-from-lambda"
  })
}

# Egress: Allow Proxy → RDS on the DB port
resource "aws_vpc_security_group_egress_rule" "proxy_to_rds" {
  security_group_id = aws_security_group.rds_proxy.id
  description       = "Allow RDS Proxy to connect to Aurora"

  referenced_security_group_id = var.rds_security_group_id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-proxy-to-rds"
  })
}

# Allow RDS SG to accept ingress from the Proxy SG
resource "aws_vpc_security_group_ingress_rule" "rds_from_proxy" {
  security_group_id = var.rds_security_group_id
  description       = "Allow RDS Proxy to connect to Aurora"

  referenced_security_group_id = aws_security_group.rds_proxy.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-from-proxy"
  })
}

# ---------- RDS Proxy ------------------------------------------------------ #
resource "aws_db_proxy" "main" {
  name                   = "${var.project}-${var.environment}-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = var.private_subnet_ids
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]

  # TLS enforcement — all connections encrypted in transit
  require_tls = var.require_tls

  # Idle timeout — close connections from Lambda containers that go idle
  idle_client_timeout = var.idle_client_timeout

  # Enhanced logging for debugging (disable in prod for performance)
  debug_logging = var.debug_logging

  auth {
    auth_scheme = "SECRETS"
    description = "Aurora master user credentials"
    iam_auth    = "DISABLED" # Future: enable IAM DB auth
    secret_arn  = var.db_secret_arns[0]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-proxy"
  })
}

# ---------- Target Group (connection pool settings) ------------------------ #
resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name

  connection_pool_config {
    # Max percentage of Aurora max_connections the proxy can use
    max_connections_percent = var.max_connections_percent

    # Percentage of max_connections kept open as idle "warm" connections
    max_idle_connections_percent = var.max_idle_connections_percent

    # How long to wait for a connection from the pool before failing
    connection_borrow_timeout = var.connection_borrow_timeout

    # SQL to run when a connection is borrowed (set session defaults)
    init_query = var.init_query

    # Session pinning filters — reduce pinning for better multiplexing
    session_pinning_filters = var.session_pinning_filters
  }
}

# ---------- Target (Aurora Cluster) ---------------------------------------- #
resource "aws_db_proxy_target" "aurora" {
  db_proxy_name          = aws_db_proxy.main.name
  target_group_name      = aws_db_proxy_default_target_group.main.name
  db_cluster_identifier  = var.cluster_identifier
}

# ---------- CloudWatch Log Group ------------------------------------------- #
resource "aws_cloudwatch_log_group" "rds_proxy" {
  name              = "/aws/rds/proxy/${aws_db_proxy.main.name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-proxy-logs"
  })
}
