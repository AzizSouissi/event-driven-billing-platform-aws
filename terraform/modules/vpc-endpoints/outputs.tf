###############################################################################
# VPC Endpoints Module — Outputs
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# Gateway Endpoints
# ──────────────────────────────────────────────────────────────────────────── #

output "s3_endpoint_id" {
  description = "S3 Gateway VPC endpoint ID"
  value       = var.enable_s3_endpoint ? aws_vpc_endpoint.s3[0].id : null
}

output "dynamodb_endpoint_id" {
  description = "DynamoDB Gateway VPC endpoint ID"
  value       = var.enable_dynamodb_endpoint ? aws_vpc_endpoint.dynamodb[0].id : null
}

# ──────────────────────────────────────────────────────────────────────────── #
# Interface Endpoints
# ──────────────────────────────────────────────────────────────────────────── #

output "sqs_endpoint_id" {
  description = "SQS Interface endpoint ID"
  value       = var.enable_sqs_endpoint ? aws_vpc_endpoint.sqs[0].id : null
}

output "secretsmanager_endpoint_id" {
  description = "Secrets Manager Interface endpoint ID"
  value       = var.enable_secretsmanager_endpoint ? aws_vpc_endpoint.secretsmanager[0].id : null
}

output "kms_endpoint_id" {
  description = "KMS Interface endpoint ID"
  value       = var.enable_kms_endpoint ? aws_vpc_endpoint.kms[0].id : null
}

output "logs_endpoint_id" {
  description = "CloudWatch Logs Interface endpoint ID"
  value       = var.enable_logs_endpoint ? aws_vpc_endpoint.logs[0].id : null
}

output "sns_endpoint_id" {
  description = "SNS Interface endpoint ID"
  value       = var.enable_sns_endpoint ? aws_vpc_endpoint.sns[0].id : null
}

output "ssm_endpoint_id" {
  description = "SSM Parameter Store Interface endpoint ID"
  value       = var.enable_ssm_endpoint ? aws_vpc_endpoint.ssm[0].id : null
}

# ──────────────────────────────────────────────────────────────────────────── #
# Security Group
# ──────────────────────────────────────────────────────────────────────────── #

output "endpoint_security_group_id" {
  description = "Security group ID for Interface endpoints"
  value       = var.enable_interface_endpoints ? aws_security_group.vpc_endpoints[0].id : null
}
