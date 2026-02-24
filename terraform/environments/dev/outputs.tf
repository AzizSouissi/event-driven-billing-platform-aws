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
