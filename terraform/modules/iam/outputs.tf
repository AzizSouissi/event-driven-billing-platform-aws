output "lambda_execution_role_arn" {
  description = "ARN of the Lambda execution IAM role"
  value       = aws_iam_role.lambda_execution.arn
}

output "lambda_execution_role_name" {
  description = "Name of the Lambda execution IAM role"
  value       = aws_iam_role.lambda_execution.name
}

output "apigw_cloudwatch_role_arn" {
  description = "ARN of the API Gateway CloudWatch logging role"
  value       = aws_iam_role.apigw_cloudwatch.arn
}
