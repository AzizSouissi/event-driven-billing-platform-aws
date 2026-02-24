# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Function Outputs
# ──────────────────────────────────────────────────────────────────────────── #

output "lambda_function_arns" {
  description = "Map of function name → ARN"
  value       = { for k, v in aws_lambda_function.api : k => v.arn }
}

output "lambda_function_names" {
  description = "Map of function name → name"
  value       = { for k, v in aws_lambda_function.api : k => v.function_name }
}

output "lambda_function_invoke_arns" {
  description = "Map of function name → invoke ARN"
  value       = { for k, v in aws_lambda_function.api : k => v.invoke_arn }
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway Outputs
# ──────────────────────────────────────────────────────────────────────────── #

output "stage_id" {
  description = "Versioned stage ID"
  value       = aws_apigatewayv2_stage.versioned.id
}

output "stage_invoke_url" {
  description = "Full invoke URL for the versioned stage"
  value       = aws_apigatewayv2_stage.versioned.invoke_url
}

output "route_ids" {
  description = "Map of function name → route ID"
  value       = { for k, v in aws_apigatewayv2_route.api : k => v.id }
}

output "api_access_log_group" {
  description = "CloudWatch log group for API access logs"
  value       = aws_cloudwatch_log_group.api_access_logs.name
}

# ──────────────────────────────────────────────────────────────────────────── #
# Schema Outputs
# ──────────────────────────────────────────────────────────────────────────── #

output "schema_parameter_arns" {
  description = "Map of schema name → SSM parameter ARN"
  value       = { for k, v in aws_ssm_parameter.request_schema : k => v.arn }
}
