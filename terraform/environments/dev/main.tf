###############################################################################
# Dev Environment — Root Module
# ──────────────────────────────────────────────────────────────────────────────
# Composes the VPC and IAM modules and exposes their outputs for downstream
# consumers (e.g. Lambda deploy pipeline, RDS module, API Gateway module).
###############################################################################

data "aws_caller_identity" "current" {}

# ---------- VPC ------------------------------------------------------------ #
module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment
  vpc_cidr    = var.vpc_cidr

  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_port              = var.db_port

  tags = local.common_tags
}

# ---------- IAM ------------------------------------------------------------ #
module "iam" {
  source = "../../modules/iam"

  project        = var.project
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id

  # Allow Lambda to read the RDS-managed master password secret
  additional_secret_arns = [module.rds.master_user_secret_arn]

  # Allow Lambda to decrypt the RDS secret (encrypted with Aurora CMK)
  kms_key_arns = [module.rds.kms_key_arn]

  tags = local.common_tags
}

# ---------- Auth (Cognito + API Gateway) ----------------------------------- #
module "auth" {
  source = "../../modules/auth"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  allow_admin_create_user_only = var.allow_admin_create_user_only
  password_minimum_length      = var.password_minimum_length
  advanced_security_mode       = var.advanced_security_mode

  access_token_validity_minutes = var.access_token_validity_minutes
  id_token_validity_minutes     = var.id_token_validity_minutes
  refresh_token_validity_days   = var.refresh_token_validity_days

  callback_urls      = var.callback_urls
  logout_urls        = var.logout_urls
  cors_allow_origins = var.cors_allow_origins
  log_retention_days = var.log_retention_days

  tags = local.common_tags
}

# ---------- API (Routes, Lambda, Throttling) ------------------------------- #
module "api" {
  source = "../../modules/api"

  project     = var.project
  environment = var.environment

  # From auth module
  api_id            = module.auth.api_id
  api_execution_arn = module.auth.api_execution_arn
  authorizer_id     = module.auth.authorizer_id

  # From VPC module
  private_subnet_ids       = module.vpc.private_subnet_ids
  lambda_security_group_id = module.vpc.lambda_security_group_id

  # From IAM module
  lambda_execution_role_arn = module.iam.lambda_execution_role_arn

  # Stage
  stage_name  = var.api_stage_name
  auto_deploy = true

  # Database
  db_secret_arn = module.rds.master_user_secret_arn

  # SNS topic for event-driven consumers
  sns_topic_arn = module.events.sns_topic_arn

  # Throttling
  default_throttle_burst_limit = var.default_throttle_burst_limit
  default_throttle_rate_limit  = var.default_throttle_rate_limit

  # Lambda function definitions
  lambda_functions = {
    create-tenant = {
      description           = "Create a new tenant"
      route_key             = "POST /v1/tenants"
      handler               = "index.handler"
      runtime               = "nodejs20.x"
      timeout               = 10
      memory_size           = 256
      environment_variables = {}
      throttle_burst_limit  = 20   # Low — admin-only, rare operation
      throttle_rate_limit   = 10
    }

    create-subscription = {
      description           = "Create a subscription for a tenant"
      route_key             = "POST /v1/subscriptions"
      handler               = "index.handler"
      runtime               = "nodejs20.x"
      timeout               = 10
      memory_size           = 256
      environment_variables = {}
      throttle_burst_limit  = 50
      throttle_rate_limit   = 25
    }

    list-invoices = {
      description           = "List invoices for the authenticated tenant"
      route_key             = "GET /v1/invoices"
      handler               = "index.handler"
      runtime               = "nodejs20.x"
      timeout               = 10
      memory_size           = 256
      environment_variables = {}
      throttle_burst_limit  = 200  # High — frequent read operation
      throttle_rate_limit   = 100
    }

    ingest-event = {
      description           = "Ingest a billing event"
      route_key             = "POST /v1/events"
      handler               = "index.handler"
      runtime               = "nodejs20.x"
      timeout               = 5
      memory_size           = 128
      environment_variables = {}
      throttle_burst_limit  = 500  # Highest — event ingestion is bursty
      throttle_rate_limit   = 200
    }
  }

  # Request validation schemas
  request_schemas = {
    create-tenant = jsonencode({
      "$schema" = "http://json-schema.org/draft-07/schema#"
      type       = "object"
      required   = ["name", "email"]
      properties = {
        name = {
          type      = "string"
          minLength = 1
          maxLength = 128
        }
        email = {
          type   = "string"
          format = "email"
        }
        plan = {
          type = "string"
          enum = ["free", "starter", "professional", "enterprise"]
        }
      }
      additionalProperties = false
    })

    create-subscription = jsonencode({
      "$schema" = "http://json-schema.org/draft-07/schema#"
      type       = "object"
      required   = ["plan_id", "billing_cycle"]
      properties = {
        plan_id = {
          type      = "string"
          minLength = 1
        }
        billing_cycle = {
          type = "string"
          enum = ["monthly", "annual"]
        }
        starts_at = {
          type   = "string"
          format = "date-time"
        }
      }
      additionalProperties = false
    })

    ingest-event = jsonencode({
      "$schema" = "http://json-schema.org/draft-07/schema#"
      type       = "object"
      required   = ["event_type", "payload"]
      properties = {
        event_type = {
          type = "string"
          enum = ["usage", "charge", "credit", "refund"]
        }
        idempotency_key = {
          type      = "string"
          minLength = 1
          maxLength = 128
        }
        payload = {
          type = "object"
        }
        occurred_at = {
          type   = "string"
          format = "date-time"
        }
      }
      additionalProperties = false
    })
  }

  # Logging
  lambda_log_retention_days = var.log_retention_days
  api_log_retention_days    = var.log_retention_days

  tags = local.common_tags
}

# ---------- Events (SNS fan-out + SQS consumers) -------------------------- #
module "events" {
  source = "../../modules/events"

  project     = var.project
  environment = var.environment

  # From VPC module
  private_subnet_ids       = module.vpc.private_subnet_ids
  lambda_security_group_id = module.vpc.lambda_security_group_id

  # From IAM module
  lambda_execution_role_arn = module.iam.lambda_execution_role_arn

  # Database
  db_secret_arn = module.rds.master_user_secret_arn

  # Logging
  log_retention_days = var.log_retention_days

  tags = local.common_tags
}

# ---------- RDS (Aurora Serverless v2) ------------------------------------- #
module "rds" {
  source = "../../modules/rds"

  project     = var.project
  environment = var.environment

  # From VPC module
  db_subnet_group_name  = module.vpc.db_subnet_group_name
  rds_security_group_id = module.vpc.rds_security_group_id
  db_port               = var.db_port

  # Engine
  engine_version  = var.aurora_engine_version
  database_name   = var.aurora_database_name
  master_username = var.aurora_master_username

  # Serverless v2 scaling
  serverless_min_acu = var.aurora_min_acu
  serverless_max_acu = var.aurora_max_acu

  # Topology
  reader_count = var.aurora_reader_count

  # Backup & maintenance
  backup_retention_days        = var.aurora_backup_retention_days
  skip_final_snapshot          = var.aurora_skip_final_snapshot
  deletion_protection          = var.aurora_deletion_protection
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"

  # Monitoring
  performance_insights_retention_days = 7
  enhanced_monitoring_interval        = 60
  log_retention_days                  = var.log_retention_days

  tags = local.common_tags
}

# ---------- VPC Endpoints (reduce NAT costs) ------------------------------- #
module "vpc_endpoints" {
  source = "../../modules/vpc-endpoints"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  # From VPC module
  vpc_id                   = module.vpc.vpc_id
  vpc_cidr                 = module.vpc.vpc_cidr
  private_subnet_ids       = module.vpc.private_subnet_ids
  private_route_table_ids  = module.vpc.private_route_table_ids
  lambda_security_group_id = module.vpc.lambda_security_group_id

  # Gateway endpoints (free — always on)
  enable_s3_endpoint       = true
  enable_dynamodb_endpoint = true

  # Interface endpoints (individually toggleable)
  enable_interface_endpoints     = var.enable_vpc_interface_endpoints
  enable_sqs_endpoint            = var.enable_vpc_interface_endpoints
  enable_secretsmanager_endpoint = var.enable_vpc_interface_endpoints
  enable_kms_endpoint            = var.enable_vpc_interface_endpoints
  enable_logs_endpoint           = var.enable_vpc_interface_endpoints
  enable_sns_endpoint            = var.enable_vpc_interface_endpoints
  enable_ssm_endpoint            = var.enable_vpc_interface_endpoints

  tags = local.common_tags
}

# ---------- Observability (Dashboard, Alarms, Metrics) --------------------- #
module "observability" {
  source = "../../modules/observability"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  # All Lambda function names (API + event consumers)
  lambda_function_names = concat(
    values(module.api.lambda_function_names),
    values(module.events.consumer_function_names),
  )

  # All Lambda log group names for metric filters
  lambda_log_group_names = [
    for fn_name in concat(
      values(module.api.lambda_function_names),
      values(module.events.consumer_function_names),
    ) : "/aws/lambda/${fn_name}"
  ]

  # API Gateway
  api_id = module.auth.api_id

  # SQS queues for dashboard
  sqs_queue_names = [
    for name in keys(module.events.processing_queue_arns) :
    "${var.project}-${var.environment}-${name}"
  ]
  dlq_names = [
    for name in keys(module.events.dlq_arns) :
    "${var.project}-${var.environment}-${name}-dlq"
  ]

  # RDS (now provided by the rds module)
  rds_instance_id = module.rds.writer_instance_id

  # Alarm notifications
  alarm_email = var.alarm_email

  tags = local.common_tags
}

# ---------- Locals --------------------------------------------------------- #
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
