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

# Events / SNS + SQS
output "sns_topic_arn" {
  description = "SNS topic ARN for subscription events"
  value       = module.events.sns_topic_arn
}

output "processing_queue_arns" {
  description = "SQS processing queue ARNs"
  value       = module.events.processing_queue_arns
}

output "dlq_arns" {
  description = "Dead-letter queue ARNs"
  value       = module.events.dlq_arns
}

output "consumer_function_names" {
  description = "Map of event consumer Lambda function names"
  value       = module.events.consumer_function_names
}

output "dlq_alarm_arns" {
  description = "CloudWatch alarm ARNs for DLQ monitoring"
  value       = module.events.dlq_alarm_arns
}

# Observability
output "dashboard_name" {
  description = "CloudWatch operations dashboard name"
  value       = module.observability.dashboard_name
}

output "alarm_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  value       = module.observability.alarm_topic_arn
}

output "lambda_error_rate_alarm_arns" {
  description = "Map of Lambda error rate alarm ARNs"
  value       = module.observability.lambda_error_rate_alarm_arns
}

# RDS — Aurora Serverless v2
output "aurora_cluster_endpoint" {
  description = "Aurora writer endpoint (read/write)"
  value       = module.rds.cluster_endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint (read-only, load-balanced)"
  value       = module.rds.reader_endpoint
}

output "aurora_cluster_id" {
  description = "Aurora cluster identifier"
  value       = module.rds.cluster_id
}

output "aurora_database_name" {
  description = "Default database name"
  value       = module.rds.database_name
}

output "aurora_master_user_secret_arn" {
  description = "Secrets Manager ARN for the master password"
  value       = module.rds.master_user_secret_arn
  sensitive   = true
}

output "aurora_writer_instance_id" {
  description = "Aurora writer instance ID (for CloudWatch monitoring)"
  value       = module.rds.writer_instance_id
}

# VPC Endpoints
output "s3_endpoint_id" {
  description = "S3 Gateway VPC endpoint ID"
  value       = module.vpc_endpoints.s3_endpoint_id
}

output "dynamodb_endpoint_id" {
  description = "DynamoDB Gateway VPC endpoint ID"
  value       = module.vpc_endpoints.dynamodb_endpoint_id
}

# WAF
output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = module.waf.web_acl_arn
}

output "waf_web_acl_name" {
  description = "WAF Web ACL name"
  value       = module.waf.web_acl_name
}

# Pre-Token-Generation Lambda
output "pre_token_function_name" {
  description = "Pre-token-generation Lambda function name"
  value       = module.pre_token.function_name
}

output "pre_token_function_arn" {
  description = "Pre-token-generation Lambda function ARN"
  value       = module.pre_token.function_arn
}
