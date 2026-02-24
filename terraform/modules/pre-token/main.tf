###############################################################################
# Pre-Token-Generation Lambda Module
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • Dedicated module for the Cognito pre-token-generation trigger because it
#     has a different lifecycle than API Lambda functions — triggered by
#     Cognito, not API Gateway.
#
#   • Runs inside the VPC to query Aurora for tenant details (plan tier,
#     subscription status, feature flags).  Reuses the same private subnets
#     and Lambda security group as the API functions.
#
#   • Uses the same shared IAM execution role as other Lambda functions.
#     The role already has Secrets Manager, VPC, CloudWatch, and KMS
#     permissions needed for DB access.
#
#   • aws_lambda_permission grants Cognito the right to invoke this function.
#     The source_arn is scoped to the specific User Pool.
#
#   • Placeholder zip is used (same pattern as the API module) — real code is
#     deployed via CI/CD.  This avoids coupling Terraform apply to code builds.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Log Group
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_log_group" "pre_token" {
  name              = "/aws/lambda/${var.project}-${var.environment}-pre-token-generation"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-pre-token-generation-logs"
    Function = "pre-token-generation"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Placeholder Deployment Package
# ──────────────────────────────────────────────────────────────────────────── #

data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"

  source {
    content  = <<-EOF
      exports.handler = async (event) => {
        // Placeholder — deploy real code via CI/CD
        return event;
      };
    EOF
    filename = "index.js"
  }
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Function
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_lambda_function" "pre_token" {
  function_name = "${var.project}-${var.environment}-pre-token-generation"
  description   = "Cognito pre-token-generation trigger — enriches JWT with tenant plan tier, feature flags, and status"
  role          = var.lambda_execution_role_arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = 10
  memory_size   = 256

  # Placeholder package — CI/CD deploys real code
  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  # X-Ray distributed tracing
  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  # VPC configuration — needs DB access for tenant lookup
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  environment {
    variables = {
      ENVIRONMENT        = var.environment
      PROJECT            = var.project
      LOG_LEVEL          = var.environment == "prod" ? "WARN" : "DEBUG"
      DB_SECRET_ARN      = var.db_secret_arn
      RDS_PROXY_ENDPOINT = var.rds_proxy_endpoint
    }
  }

  depends_on = [aws_cloudwatch_log_group.pre_token]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-pre-token-generation"
    Function = "pre-token-generation"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Permission — Allow Cognito to invoke this function
# ──────────────────────────────────────────────────────────────────────────── #
# Note: The `user_pool_arn` is optional. When both the pre-token module and
# the auth module are composed in the same root, you can pass the User Pool
# ARN to scope the permission.  If omitted, the permission allows any Cognito
# User Pool in the account to invoke this Lambda.

resource "aws_lambda_permission" "cognito_invoke" {
  count = var.user_pool_arn != "" ? 1 : 0

  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_token.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = var.user_pool_arn
}
