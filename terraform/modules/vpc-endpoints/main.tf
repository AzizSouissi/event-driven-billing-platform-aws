###############################################################################
# VPC Endpoints Module — Reduce NAT Gateway Costs
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • GATEWAY ENDPOINTS (S3, DynamoDB):
#       – Free, no per-hour or per-GB charges
#       – Add a route to the private route table (no DNS change needed)
#       – Lambda/RDS traffic to S3 and DynamoDB stays on the AWS backbone
#         instead of traversing the NAT Gateway ($0.045/GB saved)
#       – S3 is used by Lambda for deployment packages, CloudWatch for log
#         delivery, and potentially data export.  DynamoDB is used for
#         Terraform state locking.
#
#   • INTERFACE ENDPOINTS (SQS, Secrets Manager, KMS, CloudWatch Logs):
#       – PrivateLink: creates ENIs in private subnets with private IPs
#       – $0.01/hr per AZ + $0.01/GB processed (much cheaper than NAT at scale)
#       – SQS: Lambda event source mappings poll SQS from within VPC
#       – Secrets Manager: Lambda fetches DB credentials on cold start
#       – KMS: Used for secret decryption (Secrets Manager) and Aurora encryption
#       – CloudWatch Logs: Lambda sends logs via VPC; without this endpoint,
#         all log data traverses NAT ($0.045/GB)
#
#   • PRIVATE DNS: Enabled for all interface endpoints.  This means
#     standard AWS SDK calls (e.g., sqs.us-east-1.amazonaws.com) resolve
#     to the VPC endpoint's private IP automatically — no code changes.
#
#   • SECURITY GROUP: Interface endpoints get their own SG allowing
#     HTTPS (443) from the Lambda SG and VPC CIDR.  This is least-privilege —
#     only VPC resources can reach the endpoints.
#
#   • COST MODEL (approximate for dev):
#       – Gateway endpoints (S3, DynamoDB): Free
#       – Interface endpoints: ~$0.01/hr × 2 AZs × 4 services = ~$58/mo
#       – BUT this REPLACES NAT data transfer for these services:
#         NAT processes $0.045/GB for all AWS API traffic.  With endpoints,
#         only truly external traffic (webhooks, etc.) goes through NAT.
#       – For high-throughput systems: interface endpoints save money at
#         ~1.3 TB/mo breakeven point per service.
#       – All endpoints can be individually enabled/disabled via variables.
###############################################################################

# ---------- Security Group for Interface Endpoints ------------------------- #
# Interface endpoints use ENIs, so they need a security group.
# Allows HTTPS from Lambda SG and VPC CIDR.
resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name_prefix = "${var.project}-${var.environment}-vpce-"
  description = "Security group for VPC Interface Endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTPS from Lambda functions"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.lambda_security_group_id]
  }

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow responses"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# GATEWAY ENDPOINTS (Free — always recommended)
# ══════════════════════════════════════════════════════════════════════════════

# ---------- S3 Gateway Endpoint -------------------------------------------- #
# Routes S3 traffic through VPC (Lambda deployments, CloudWatch log delivery,
# potential data exports).  Free — zero reason not to use it.
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = var.private_route_table_ids

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-s3"
  })
}

# ---------- DynamoDB Gateway Endpoint -------------------------------------- #
# Routes DynamoDB traffic through VPC.  Used by Terraform state locking
# and potentially by application (future: session store, caching).  Free.
resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_dynamodb_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = var.private_route_table_ids

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-dynamodb"
  })
}

# ══════════════════════════════════════════════════════════════════════════════
# INTERFACE ENDPOINTS (PrivateLink — pay per hour + per GB)
# ══════════════════════════════════════════════════════════════════════════════

# ---------- SQS Interface Endpoint ----------------------------------------- #
# Lambda event source mappings poll SQS from within the VPC.  Without this
# endpoint, every SQS API call goes through NAT.  High-throughput queues
# generate significant NAT data transfer costs.
resource "aws_vpc_endpoint" "sqs" {
  count = var.enable_sqs_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sqs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-sqs"
  })
}

# ---------- Secrets Manager Interface Endpoint ----------------------------- #
# Lambda fetches DB credentials from Secrets Manager on cold start.
# Without this endpoint, every cold start's GetSecretValue call traverses NAT.
resource "aws_vpc_endpoint" "secretsmanager" {
  count = var.enable_secretsmanager_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-secretsmanager"
  })
}

# ---------- KMS Interface Endpoint ----------------------------------------- #
# Used by Secrets Manager for decryption and Aurora for storage encryption.
# Keeps all crypto operations within the VPC.
resource "aws_vpc_endpoint" "kms" {
  count = var.enable_kms_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.kms"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-kms"
  })
}

# ---------- CloudWatch Logs Interface Endpoint ----------------------------- #
# All Lambda log output goes to CloudWatch Logs.  At scale, this is the
# highest-bandwidth AWS API from VPC.  Routing via endpoint avoids NAT
# data processing charges on every log line.
resource "aws_vpc_endpoint" "logs" {
  count = var.enable_logs_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-logs"
  })
}

# ---------- SNS Interface Endpoint ----------------------------------------- #
# Lambda publishes subscription events to SNS.  Keeps publish traffic
# within VPC instead of traversing NAT.
resource "aws_vpc_endpoint" "sns" {
  count = var.enable_sns_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sns"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-sns"
  })
}

# ---------- SSM Interface Endpoint ----------------------------------------- #
# Lambda loads JSON schemas from SSM Parameter Store on cold start.
resource "aws_vpc_endpoint" "ssm" {
  count = var.enable_ssm_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpce-ssm"
  })
}
