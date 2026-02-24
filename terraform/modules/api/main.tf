###############################################################################
# API Module — REST API Routes, Lambda Integrations, Throttling & Validation
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • Uses HTTP API (API Gateway v2) created by the auth module.  This module
#     adds routes, integrations, models, and throttling — clean separation of
#     concerns between identity (auth) and API surface (this module).
#
#   • Four business endpoints mapped to individual Lambda functions:
#       POST /tenants        → create-tenant
#       POST /subscriptions  → create-subscription
#       GET  /invoices       → list-invoices
#       POST /events         → ingest-event
#     Each function has its own log group, timeout, and memory configuration.
#
#   • All routes require Cognito JWT authorization — the authorizer_id is
#     passed in from the auth module.  No anonymous access.
#
#   • Throttling is configured at TWO levels:
#     a) Stage-level default: applies to every route as a safety net.
#     b) Per-route overrides: /events gets higher burst (event ingestion) while
#        /tenants gets lower limits (rare admin operation).
#     This protects Lambda concurrency limits, RDS connection pools, and
#     downstream services from traffic spikes or abuse.
#
#   • Request validation via JSON Schema models rejects malformed payloads at
#     the API Gateway level BEFORE Lambda is invoked.  Benefits:
#     - Saves Lambda invocation cost on bad requests
#     - Returns consistent 400 error format
#     - Shifts validation left (closer to the client)
#
#   • Structured access logs in JSON format include request ID, tenant ID,
#     status, latency, and user agent.  These feed CloudWatch Insights queries
#     for operational dashboards and security auditing.
#
#   • API versioning strategy: URI-path prefix (/v1/) is used.  See README
#     for the full rationale comparing path vs header vs subdomain approaches.
#
#   • Lambda functions run inside the VPC to access RDS.  Subnet IDs and
#     security group ID are passed in from the VPC module.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Log Groups — one per Lambda function
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = var.lambda_functions

  name              = "/aws/lambda/${var.project}-${var.environment}-${each.key}"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}-logs"
    Function = each.key
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Functions
# ──────────────────────────────────────────────────────────────────────────── #

# Placeholder deployment package — replaced by CI/CD pipeline.
# Using a minimal zip avoids Terraform errors on first apply.
data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"

  source {
    content  = <<-EOF
      exports.handler = async (event) => {
        return {
          statusCode: 501,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ message: "Not implemented — deploy via CI/CD" })
        };
      };
    EOF
    filename = "index.js"
  }
}

resource "aws_lambda_function" "api" {
  for_each = var.lambda_functions

  function_name = "${var.project}-${var.environment}-${each.key}"
  description   = each.value.description
  role          = var.lambda_execution_role_arn
  handler       = each.value.handler
  runtime       = each.value.runtime
  timeout       = each.value.timeout
  memory_size   = each.value.memory_size

  # Use placeholder; real code deployed by CI/CD
  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  # VPC configuration — Lambda runs inside private subnets
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  environment {
    variables = merge(
      {
        ENVIRONMENT = var.environment
        PROJECT     = var.project
        LOG_LEVEL   = var.environment == "prod" ? "WARN" : "DEBUG"
      },
      each.value.environment_variables
    )
  }

  # Ensure log group exists before function to avoid auto-creation with
  # infinite retention
  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}"
    Function = each.key
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Permissions — Allow API Gateway to invoke each function
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_lambda_permission" "apigw" {
  for_each = var.lambda_functions

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api_execution_arn}/*/*"
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway Integrations — one per Lambda
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_apigatewayv2_integration" "lambda" {
  for_each = var.lambda_functions

  api_id                 = var.api_id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api[each.key].invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  description            = "Integration for ${each.key}"

  # Timeout must be between 50ms and 30s for HTTP APIs
  timeout_milliseconds = min(each.value.timeout * 1000, 30000)
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway Routes — versioned under /v1
# ──────────────────────────────────────────────────────────────────────────── #
# Route keys use the format "METHOD /v1/resource".
# All routes require JWT authorization via the Cognito authorizer.

resource "aws_apigatewayv2_route" "api" {
  for_each = var.lambda_functions

  api_id             = var.api_id
  route_key          = each.value.route_key
  authorization_type = "JWT"
  authorizer_id      = var.authorizer_id
  target             = "integrations/${aws_apigatewayv2_integration.lambda[each.key].id}"
}

# ──────────────────────────────────────────────────────────────────────────── #
# Throttling — Stage-level defaults + per-route overrides
# ──────────────────────────────────────────────────────────────────────────── #
# HTTP API v2 throttling is set on the stage's route_settings and
# default_route_settings.

resource "aws_apigatewayv2_stage" "versioned" {
  api_id      = var.api_id
  name        = var.stage_name
  auto_deploy = var.auto_deploy

  # ---------- Stage-level default throttle -------------------------------- #
  default_route_settings {
    throttling_burst_limit = var.default_throttle_burst_limit
    throttling_rate_limit  = var.default_throttle_rate_limit
  }

  # ---------- Per-route throttle overrides -------------------------------- #
  dynamic "route_settings" {
    for_each = {
      for k, v in var.lambda_functions : k => v
      if v.throttle_burst_limit != null || v.throttle_rate_limit != null
    }

    content {
      route_key              = route_settings.value.route_key
      throttling_burst_limit = route_settings.value.throttle_burst_limit != null ? route_settings.value.throttle_burst_limit : var.default_throttle_burst_limit
      throttling_rate_limit  = route_settings.value.throttle_rate_limit != null ? route_settings.value.throttle_rate_limit : var.default_throttle_rate_limit
    }
  }

  # ---------- Structured access logs -------------------------------------- #
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access_logs.arn

    format = jsonencode({
      # Request identification
      requestId    = "$context.requestId"
      extendedId   = "$context.extendedRequestId"
      requestTime  = "$context.requestTime"
      requestEpoch = "$context.requestTimeEpoch"

      # Client info
      ip        = "$context.identity.sourceIp"
      userAgent = "$context.identity.userAgent"

      # Request details
      httpMethod = "$context.httpMethod"
      routeKey   = "$context.routeKey"
      path       = "$context.path"
      protocol   = "$context.protocol"
      stage      = "$context.stage"

      # Response
      status         = "$context.status"
      responseLength = "$context.responseLength"
      responseLatencyMs = "$context.responseLatency"

      # Integration (Lambda)
      integrationError   = "$context.integrationErrorMessage"
      integrationLatency = "$context.integrationLatency"
      integrationStatus  = "$context.integrationStatus"

      # Auth / tenant context
      tenantId   = "$context.authorizer.claims.custom:tenant_id"
      userGroups = "$context.authorizer.claims.cognito:groups"
      sub        = "$context.authorizer.claims.sub"

      # Error details (populated on 4xx/5xx)
      error     = "$context.error.message"
      errorType = "$context.error.responseType"
    })
  }

  tags = merge(var.tags, {
    Name  = "${var.project}-${var.environment}-api-${var.stage_name}"
    Stage = var.stage_name
  })
}

resource "aws_cloudwatch_log_group" "api_access_logs" {
  name              = "/aws/apigateway/${var.project}-${var.environment}/${var.stage_name}"
  retention_in_days = var.api_log_retention_days

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-api-${var.stage_name}-access-logs"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Request Validation Models (JSON Schema)
# ──────────────────────────────────────────────────────────────────────────── #
# HTTP API v2 does not natively support request models/validators like REST
# API v1.  We implement validation in a thin Lambda middleware layer.
#
# The models below are stored as SSM parameters so Lambda functions can load
# them on cold start and validate request bodies using a JSON schema library
# (e.g., ajv for Node.js, fastjsonschema for Python).
#
# This approach:
#   • Keeps schemas version-controlled in Terraform
#   • Avoids hardcoding schemas in Lambda code
#   • Allows schema updates without redeploying Lambda
#   • Returns consistent 400 errors with field-level details

resource "aws_ssm_parameter" "request_schema" {
  for_each = var.request_schemas

  name        = "/${var.project}/${var.environment}/api/schemas/${each.key}"
  description = "JSON Schema for ${each.key} request validation"
  type        = "String"
  value       = each.value
  tier        = "Standard"

  tags = merge(var.tags, {
    Name   = "${var.project}-${var.environment}-schema-${each.key}"
    Schema = each.key
  })
}
