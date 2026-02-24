# ──────────────────────────────────────────────────────────────────────────── #
# SNS
# ──────────────────────────────────────────────────────────────────────────── #

output "alarm_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  value       = aws_sns_topic.alarms.arn
}

output "alarm_topic_name" {
  description = "SNS topic name for alarm notifications"
  value       = aws_sns_topic.alarms.name
}

# ──────────────────────────────────────────────────────────────────────────── #
# Alarms
# ──────────────────────────────────────────────────────────────────────────── #

output "lambda_error_rate_alarm_arns" {
  description = "Map of function name → error rate alarm ARN"
  value       = { for k, v in aws_cloudwatch_metric_alarm.lambda_error_rate : k => v.arn }
}

output "lambda_throttle_alarm_arns" {
  description = "Map of function name → throttle alarm ARN"
  value       = { for k, v in aws_cloudwatch_metric_alarm.lambda_throttles : k => v.arn }
}

output "rds_cpu_alarm_arn" {
  description = "RDS CPU alarm ARN (empty if no RDS)"
  value       = length(aws_cloudwatch_metric_alarm.rds_cpu) > 0 ? aws_cloudwatch_metric_alarm.rds_cpu[0].arn : ""
}

output "api_5xx_alarm_arn" {
  description = "API Gateway 5xx alarm ARN"
  value       = length(aws_cloudwatch_metric_alarm.api_5xx) > 0 ? aws_cloudwatch_metric_alarm.api_5xx[0].arn : ""
}

# ──────────────────────────────────────────────────────────────────────────── #
# Dashboard
# ──────────────────────────────────────────────────────────────────────────── #

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_arn" {
  description = "CloudWatch dashboard ARN"
  value       = aws_cloudwatch_dashboard.main.dashboard_arn
}
