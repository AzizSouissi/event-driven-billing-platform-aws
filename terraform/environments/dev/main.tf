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

# ---------- Locals --------------------------------------------------------- #
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
