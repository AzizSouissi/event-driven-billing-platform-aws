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

  # Pre-token-generation Lambda — enriches JWT with plan tier, features
  pre_token_generation_lambda_arn = module.pre_token.function_arn

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

  # RDS Proxy — Lambda connects through proxy for connection pooling
  rds_proxy_endpoint = module.rds_proxy.proxy_endpoint

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

  # X-Ray distributed tracing
  enable_xray_tracing = var.enable_xray_tracing

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

  # RDS Proxy — consumer Lambdas connect through proxy for connection pooling
  rds_proxy_endpoint = module.rds_proxy.proxy_endpoint

  # Logging
  log_retention_days = var.log_retention_days

  # X-Ray distributed tracing (Lambda consumers + SNS topic)
  enable_xray_tracing = var.enable_xray_tracing

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

# ---------- RDS Proxy (Lambda connection pooling) -------------------------- #
module "rds_proxy" {
  source = "../../modules/rds-proxy"

  project     = var.project
  environment = var.environment

  # Network (same VPC / subnets as Aurora)
  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnet_ids
  lambda_security_group_id = module.vpc.lambda_security_group_id
  rds_security_group_id    = module.vpc.rds_security_group_id
  db_port                  = var.db_port

  # Aurora references
  cluster_identifier = module.rds.cluster_id
  db_secret_arns     = [module.rds.master_user_secret_arn]
  kms_key_arn        = module.rds.kms_key_arn

  # Proxy tuning (relaxed for dev)
  require_tls                 = true
  idle_client_timeout         = 1800  # 30 min
  debug_logging               = true  # Verbose in dev, disable in prod
  max_connections_percent     = 100
  max_idle_connections_percent = 50
  connection_borrow_timeout   = 120
  session_pinning_filters     = ["EXCLUDE_VARIABLE_SETS"]

  # Logging
  log_retention_days = var.log_retention_days

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

# ---------- Pre-Token-Generation Lambda ------------------------------------ #
module "pre_token" {
  source = "../../modules/pre-token"

  project     = var.project
  environment = var.environment

  # From IAM module
  lambda_execution_role_arn = module.iam.lambda_execution_role_arn

  # From VPC module (needs DB access for tenant lookup)
  private_subnet_ids       = module.vpc.private_subnet_ids
  lambda_security_group_id = module.vpc.lambda_security_group_id

  # Database credentials
  db_secret_arn = module.rds.master_user_secret_arn

  # RDS Proxy — pre-token Lambda also connects through proxy
  rds_proxy_endpoint = module.rds_proxy.proxy_endpoint

  # Logging
  log_retention_days = var.log_retention_days

  # X-Ray distributed tracing
  enable_xray_tracing = var.enable_xray_tracing

  tags = local.common_tags
}

# Cognito → Lambda invoke permission (separate resource to break circular
# dependency between auth and pre_token modules)
resource "aws_lambda_permission" "cognito_pre_token" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.pre_token.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = module.auth.user_pool_arn
}

# ---------- DLQ Reprocessor ----------------------------------------------- #
module "dlq_reprocessor" {
  source = "../../modules/dlq-reprocessor"

  project     = var.project
  environment = var.environment

  # IAM
  lambda_execution_role_arn = module.iam.lambda_execution_role_arn
  lambda_execution_role_id  = module.iam.lambda_execution_role_name

  # Queue mappings — DLQ → processing queue for each consumer
  queue_map = {
    for name in keys(module.events.processing_queue_urls) : name => {
      dlq_url          = module.events.dlq_urls[name]
      target_queue_url = module.events.processing_queue_urls[name]
    }
  }

  processing_queue_arns = module.events.processing_queue_arns

  # Logging
  log_retention_days = var.log_retention_days

  # X-Ray distributed tracing
  enable_xray_tracing = var.enable_xray_tracing

  tags = local.common_tags
}

# ---------- WAF (API Gateway Protection) ---------------------------------- #
module "waf" {
  source = "../../modules/waf"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  # API Gateway stage ARN for WAF association
  # HTTP API v2 stage ARN format: arn:aws:apigateway:{region}::/apis/{api-id}/stages/{stage-name}
  api_stage_arn = module.api.stage_arn

  # WAF configuration
  rate_limit_threshold    = var.waf_rate_limit_threshold
  managed_rules_action    = var.waf_managed_rules_action
  blocked_country_codes   = var.waf_blocked_country_codes

  # Logging
  enable_logging = var.waf_enable_logging
  log_retention_days          = var.log_retention_days
  redact_authorization_header = true

  # Alarms — send to the observability alarm topic
  alarm_sns_topic_arn = module.observability.alarm_topic_arn

  tags = local.common_tags
}

# ---------- Observability (Dashboard, Alarms, Metrics) --------------------- #
module "observability" {
  source = "../../modules/observability"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  # All Lambda function names (API + event consumers + pre-token + dlq-reprocessor)
  lambda_function_names = concat(
    values(module.api.lambda_function_names),
    values(module.events.consumer_function_names),
    [module.pre_token.function_name],
    [module.dlq_reprocessor.function_name],
  )

  # All Lambda log group names for metric filters
  lambda_log_group_names = concat(
    [
      for fn_name in concat(
        values(module.api.lambda_function_names),
        values(module.events.consumer_function_names),
      ) : "/aws/lambda/${fn_name}"
    ],
    [module.pre_token.log_group_name],
    [module.dlq_reprocessor.log_group_name],
  )

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
