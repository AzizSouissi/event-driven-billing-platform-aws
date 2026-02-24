###############################################################################
# RDS Proxy Module — Outputs
###############################################################################

output "proxy_endpoint" {
  description = "RDS Proxy endpoint — Lambda connects here instead of directly to Aurora"
  value       = aws_db_proxy.main.endpoint
}

output "proxy_arn" {
  description = "RDS Proxy ARN"
  value       = aws_db_proxy.main.arn
}

output "proxy_name" {
  description = "RDS Proxy name"
  value       = aws_db_proxy.main.name
}

output "proxy_security_group_id" {
  description = "Security group ID attached to the RDS Proxy"
  value       = aws_security_group.rds_proxy.id
}

output "proxy_log_group_name" {
  description = "CloudWatch log group for RDS Proxy logs"
  value       = aws_cloudwatch_log_group.rds_proxy.name
}
