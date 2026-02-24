# ──────────────────────────────────────────────────────────────────────────── #
# Cognito Outputs
# ──────────────────────────────────────────────────────────────────────────── #

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.main.arn
}

output "user_pool_endpoint" {
  description = "Cognito User Pool endpoint (for SDK configuration)"
  value       = aws_cognito_user_pool.main.endpoint
}

output "app_client_id" {
  description = "App Client ID (public — no secret)"
  value       = aws_cognito_user_pool_client.app.id
}

output "user_pool_domain" {
  description = "Cognito hosted UI domain"
  value       = aws_cognito_user_pool_domain.main.domain
}

output "hosted_ui_url" {
  description = "Full URL of the Cognito hosted UI"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "jwks_uri" {
  description = "JWKS URI for token signature verification"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
}

output "issuer_url" {
  description = "Token issuer URL (iss claim value)"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway Outputs
# ──────────────────────────────────────────────────────────────────────────── #

output "api_id" {
  description = "HTTP API Gateway ID"
  value       = aws_apigatewayv2_api.main.id
}

output "api_endpoint" {
  description = "HTTP API Gateway invoke URL"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "authorizer_id" {
  description = "JWT authorizer ID (attach to routes)"
  value       = aws_apigatewayv2_authorizer.cognito_jwt.id
}

output "api_log_group_name" {
  description = "CloudWatch log group for API access logs"
  value       = aws_cloudwatch_log_group.api_access_logs.name
}
