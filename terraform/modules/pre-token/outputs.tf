output "function_arn" {
  description = "Pre-token-generation Lambda function ARN"
  value       = aws_lambda_function.pre_token.arn
}

output "function_name" {
  description = "Pre-token-generation Lambda function name"
  value       = aws_lambda_function.pre_token.function_name
}

output "function_invoke_arn" {
  description = "Pre-token-generation Lambda invoke ARN"
  value       = aws_lambda_function.pre_token.invoke_arn
}

output "log_group_name" {
  description = "CloudWatch log group name for the pre-token Lambda"
  value       = aws_cloudwatch_log_group.pre_token.name
}
