###############################################################################
# IAM Module — Roles & Policies
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#   • Lambda execution role follows least-privilege:
#       – AWSLambdaVPCAccessExecutionRole: manage ENIs in VPC subnets.
#       – CloudWatch Logs: write execution logs only.
#       – Additional inline policies (RDS IAM auth, Secrets Manager, SQS, etc.)
#         should be attached per-function, NOT here.  This role is the baseline.
#   • API Gateway CloudWatch role is a GLOBAL singleton per account/region.
#       – Uses the managed AmazonAPIGatewayPushToCloudWatchLogs policy.
#       – Linked via aws_api_gateway_account so all stages inherit logging.
#   • All policies use aws_iam_policy_document data sources for type safety
#     and auditability (no raw JSON).
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Execution Role
# ──────────────────────────────────────────────────────────────────────────── #

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_execution" {
  name               = "${var.project}-${var.environment}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-exec"
  })
}

# VPC access — allows Lambda to create/delete/describe ENIs for VPC placement
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# CloudWatch Logs — scoped to the project log group prefix
data "aws_iam_policy_document" "lambda_logging" {
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.project}-${var.environment}-*",
      "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.project}-${var.environment}-*:*",
    ]
  }
}

resource "aws_iam_policy" "lambda_logging" {
  name        = "${var.project}-${var.environment}-lambda-logging"
  description = "Allow Lambda to write CloudWatch Logs"
  policy      = data.aws_iam_policy_document.lambda_logging.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-logging"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logging" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_logging.arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# Secrets Manager — Allow Lambda to read DB credentials
# ──────────────────────────────────────────────────────────────────────────── #

data "aws_iam_policy_document" "lambda_secrets" {
  statement {
    sid    = "AllowSecretsManagerRead"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
    ]

    resources = concat(
      ["arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project}/${var.environment}/*"],
      var.additional_secret_arns,
    )
  }
}

resource "aws_iam_policy" "lambda_secrets" {
  name        = "${var.project}-${var.environment}-lambda-secrets"
  description = "Allow Lambda to read secrets from Secrets Manager"
  policy      = data.aws_iam_policy_document.lambda_secrets.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-secrets"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_secrets" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_secrets.arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# KMS — Allow Lambda to decrypt secrets (RDS master password uses CMK)
# ──────────────────────────────────────────────────────────────────────────── #

data "aws_iam_policy_document" "lambda_kms" {
  count = length(var.kms_key_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowKMSDecrypt"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = var.kms_key_arns
  }
}

resource "aws_iam_policy" "lambda_kms" {
  count = length(var.kms_key_arns) > 0 ? 1 : 0

  name        = "${var.project}-${var.environment}-lambda-kms"
  description = "Allow Lambda to decrypt using KMS keys"
  policy      = data.aws_iam_policy_document.lambda_kms[0].json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-kms"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_kms" {
  count = length(var.kms_key_arns) > 0 ? 1 : 0

  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_kms[0].arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# SSM Parameter Store — Allow Lambda to read request schemas
# ──────────────────────────────────────────────────────────────────────────── #

data "aws_iam_policy_document" "lambda_ssm" {
  statement {
    sid    = "AllowSSMParameterRead"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.project}/${var.environment}/*",
    ]
  }
}

resource "aws_iam_policy" "lambda_ssm" {
  name        = "${var.project}-${var.environment}-lambda-ssm"
  description = "Allow Lambda to read SSM parameters"
  policy      = data.aws_iam_policy_document.lambda_ssm.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-ssm"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ssm" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_ssm.arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# SNS — Allow Lambda to publish subscription events
# ──────────────────────────────────────────────────────────────────────────── #

data "aws_iam_policy_document" "lambda_sns" {
  statement {
    sid    = "AllowSNSPublish"
    effect = "Allow"

    actions = [
      "sns:Publish",
    ]

    resources = [
      "arn:aws:sns:${var.aws_region}:${var.aws_account_id}:${var.project}-${var.environment}-*",
    ]
  }
}

resource "aws_iam_policy" "lambda_sns" {
  name        = "${var.project}-${var.environment}-lambda-sns"
  description = "Allow Lambda to publish to SNS topics"
  policy      = data.aws_iam_policy_document.lambda_sns.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-sns"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_sns" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_sns.arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS — Allow Lambda to consume messages and interact with DLQs
# ──────────────────────────────────────────────────────────────────────────── #

data "aws_iam_policy_document" "lambda_sqs" {
  statement {
    sid    = "AllowSQSConsume"
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]

    resources = [
      "arn:aws:sqs:${var.aws_region}:${var.aws_account_id}:${var.project}-${var.environment}-*",
    ]
  }
}

resource "aws_iam_policy" "lambda_sqs" {
  name        = "${var.project}-${var.environment}-lambda-sqs"
  description = "Allow Lambda to consume from SQS queues"
  policy      = data.aws_iam_policy_document.lambda_sqs.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-sqs"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_sqs.arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway CloudWatch Logging Role
# ──────────────────────────────────────────────────────────────────────────── #

data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    sid     = "APIGatewayAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  name               = "${var.project}-${var.environment}-apigw-cw-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-apigw-cw-role"
  })
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# Link the role to API Gateway account-level settings.
# This is a singleton — only one aws_api_gateway_account per region.
resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn
}
