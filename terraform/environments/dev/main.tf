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

# ---------- Locals --------------------------------------------------------- #
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
