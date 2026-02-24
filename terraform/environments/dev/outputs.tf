###############################################################################
# Dev Environment — Outputs
# ──────────────────────────────────────────────────────────────────────────────
# Re-exported so CI/CD and other Terraform stacks can consume via
# `terraform output -json` or `terraform_remote_state`.
###############################################################################

# VPC
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "lambda_security_group_id" {
  description = "SG to attach to Lambda functions"
  value       = module.vpc.lambda_security_group_id
}

output "rds_security_group_id" {
  description = "SG to attach to RDS instances"
  value       = module.vpc.rds_security_group_id
}

output "db_subnet_group_name" {
  description = "DB subnet group for RDS"
  value       = module.vpc.db_subnet_group_name
}

output "nat_gateway_ip" {
  description = "NAT Gateway public IP"
  value       = module.vpc.nat_gateway_ip
}

# IAM
output "lambda_execution_role_arn" {
  description = "Lambda execution role ARN"
  value       = module.iam.lambda_execution_role_arn
}

output "apigw_cloudwatch_role_arn" {
  description = "API Gateway CloudWatch role ARN"
  value       = module.iam.apigw_cloudwatch_role_arn
}

# Auth / Cognito
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = module.auth.user_pool_id
}

output "cognito_app_client_id" {
  description = "Cognito App Client ID (public)"
  value       = module.auth.app_client_id
}

output "cognito_hosted_ui_url" {
  description = "Cognito hosted UI URL"
  value       = module.auth.hosted_ui_url
}

output "cognito_jwks_uri" {
  description = "JWKS URI for JWT verification"
  value       = module.auth.jwks_uri
}

output "api_endpoint" {
  description = "HTTP API Gateway invoke URL"
  value       = module.auth.api_endpoint
}

output "api_authorizer_id" {
  description = "JWT authorizer ID for route attachment"
  value       = module.auth.authorizer_id
}

# API / Routes
output "api_stage_invoke_url" {
  description = "Versioned stage invoke URL (e.g., .../v1)"
  value       = module.api.stage_invoke_url
}

output "lambda_function_names" {
  description = "Map of API function names"
  value       = module.api.lambda_function_names
}

output "api_access_log_group" {
  description = "CloudWatch log group for API access logs"
  value       = module.api.api_access_log_group
}
