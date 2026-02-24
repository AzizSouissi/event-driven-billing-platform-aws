output "web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.api.arn
}

output "web_acl_id" {
  description = "WAF Web ACL ID"
  value       = aws_wafv2_web_acl.api.id
}

output "web_acl_name" {
  description = "WAF Web ACL name"
  value       = aws_wafv2_web_acl.api.name
}

output "web_acl_capacity" {
  description = "WAF Web ACL capacity units consumed (max 5000)"
  value       = aws_wafv2_web_acl.api.capacity
}

output "log_group_name" {
  description = "CloudWatch log group name for WAF logs (empty if logging disabled)"
  value       = var.enable_logging ? aws_cloudwatch_log_group.waf[0].name : ""
}
