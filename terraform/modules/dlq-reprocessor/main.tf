###############################################################################
# DLQ Reprocessor Module — Replay Failed Messages
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • DEDICATED MODULE: The DLQ reprocessor is separate from the events
#     module because it has a different lifecycle — it's an operational tool,
#     not a consumer.  Operators invoke it manually or on a schedule.
#
#   • MANUAL INVOCATION: The Lambda is NOT connected to an SQS event source.
#     Operators invoke it via CLI/console/step function after investigating
#     and fixing the root cause of DLQ messages.
#
#   • QUEUE MAP:  Receives a map of consumer → { dlq_url, processing_queue_url }
#     as environment variables.  This lets the Lambda know which DLQ maps
#     to which processing queue, enabling a "replay all" mode.
#
#   • IAM:  Needs both sqs:ReceiveMessage + sqs:DeleteMessage (read DLQ)
#     and sqs:SendMessage (write to processing queue).  The existing Lambda
#     role has consume permissions; we add sqs:SendMessage via an inline
#     policy scoped to our queues.
#
#   • NO VPC:  The reprocessor only talks to SQS (AWS service endpoint).
#     It doesn't need Aurora access.  Keeping it outside the VPC reduces
#     cold-start time and avoids ENI limits.
#
#   • PERMISSIONS:  Uses the shared Lambda execution role for base permissions
#     (logging, VPC).  An additional inline policy grants SQS send access.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Log Group
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_log_group" "dlq_reprocessor" {
  name              = "/aws/lambda/${var.project}-${var.environment}-dlq-reprocessor"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-dlq-reprocessor-logs"
    Function = "dlq-reprocessor"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Placeholder Deployment Package
# ──────────────────────────────────────────────────────────────────────────── #

data "archive_file" "dlq_reprocessor" {
  type        = "zip"
  output_path = "${path.module}/dlq_reprocessor.zip"

  source {
    content  = <<-EOF
      exports.handler = async (event) => {
        console.log(JSON.stringify({ message: "DLQ Reprocessor placeholder — deploy via CI/CD", event }));
        return { statusCode: 200, body: { message: "placeholder" } };
      };
    EOF
    filename = "index.js"
  }
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Function — DLQ Reprocessor
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_lambda_function" "dlq_reprocessor" {
  function_name = "${var.project}-${var.environment}-dlq-reprocessor"
  description   = "Replay failed messages from DLQs back to their processing queues"
  role          = var.lambda_execution_role_arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.timeout
  memory_size   = var.memory_size

  # Placeholder — real code deployed via CI/CD
  filename         = data.archive_file.dlq_reprocessor.output_path
  source_code_hash = data.archive_file.dlq_reprocessor.output_base64sha256

  # X-Ray distributed tracing
  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  # No VPC needed — only talks to SQS service endpoint

  environment {
    variables = {
      ENVIRONMENT = var.environment
      PROJECT     = var.project
      LOG_LEVEL   = var.environment == "prod" ? "WARN" : "DEBUG"
      # JSON map of consumer → { dlqUrl, targetQueueUrl }
      # Makes it easy to replay all DLQs without passing URLs each time
      QUEUE_MAP   = jsonencode(var.queue_map)
    }
  }

  depends_on = [aws_cloudwatch_log_group.dlq_reprocessor]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-dlq-reprocessor"
    Function = "dlq-reprocessor"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# IAM — SQS SendMessage Permission (inline, scoped to our queues)
# ──────────────────────────────────────────────────────────────────────────── #
# The shared Lambda execution role already has sqs:ReceiveMessage,
# sqs:DeleteMessage, and sqs:GetQueueAttributes.  The reprocessor
# additionally needs sqs:SendMessage to push messages back to processing queues.

resource "aws_iam_role_policy" "dlq_reprocessor_sqs_send" {
  name = "${var.project}-${var.environment}-dlq-reprocessor-sqs-send"
  role = var.lambda_execution_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSQSSendMessage"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = values(var.processing_queue_arns)
      }
    ]
  })
}
