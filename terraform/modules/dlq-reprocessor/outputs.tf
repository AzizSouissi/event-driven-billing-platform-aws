###############################################################################
# DLQ Reprocessor Module — Outputs
###############################################################################

output "function_name" {
  description = "DLQ reprocessor Lambda function name"
  value       = aws_lambda_function.dlq_reprocessor.function_name
}

output "function_arn" {
  description = "DLQ reprocessor Lambda function ARN"
  value       = aws_lambda_function.dlq_reprocessor.arn
}

output "log_group_name" {
  description = "CloudWatch log group for the DLQ reprocessor"
  value       = aws_cloudwatch_log_group.dlq_reprocessor.name
}
