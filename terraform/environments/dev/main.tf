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
  db_secret_arn = var.db_secret_arn

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

# ---------- Locals --------------------------------------------------------- #
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
