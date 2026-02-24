###############################################################################
# Events Module — SNS Fan-Out + SQS Queues + DLQs + Consumer Lambdas
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • TOPOLOGY (SNS → SQS → Lambda):
#     The "subscription created" event publishes to a single SNS topic.
#     Three SQS queues subscribe to the topic, each feeding its own Lambda:
#
#       SNS (subscription-events)
#         ├── SQS (generate-invoice)   → Lambda: generate-invoice
#         ├── SQS (send-notification)  → Lambda: send-notification
#         └── SQS (audit-log)          → Lambda: audit-log
#
#     Why SNS → SQS → Lambda (not SNS → Lambda directly)?
#       a) SQS provides built-in retry with backoff.  SNS→Lambda retries
#          only 3 times with no delay control.
#       b) SQS has native DLQ support — failed messages move to a DLQ
#          after maxReceiveCount, giving operators a recovery path.
#       c) SQS decouples producer throughput from consumer speed.
#          A slow invoice generator won't block notifications.
#       d) SQS batching — Lambda can process up to 10 messages per
#          invocation, amortizing cold-start cost.
#
#   • DEAD-LETTER QUEUES (DLQs):
#     Each processing queue has a DLQ.  Messages that fail after
#     `max_receive_count` retries land in the DLQ.  A CloudWatch alarm
#     fires when the DLQ is non-empty, paging the on-call engineer.
#     DLQ retention is 14 days — enough time to investigate and replay.
#
#   • RETRY STRATEGY:
#     SQS visibility timeout = 6× Lambda timeout = 180s.
#     This prevents a message from becoming visible again while Lambda
#     is still processing it.  After 5 failed attempts (maxReceiveCount),
#     the message moves to the DLQ.  The backoff is implicit — SQS
#     visibility timeout introduces delay between retries.
#
#   • ENCRYPTION:
#     All queues and the SNS topic use SSE with the AWS-managed SQS/SNS
#     KMS key (aws/sqs, aws/sns).  In production, use a CMK for
#     cross-account access control.
#
#   • MESSAGE FILTERING:
#     SNS supports filter policies per subscription.  Currently all three
#     consumers receive all events.  To add event-type filtering later,
#     add `filter_policy` to the aws_sns_topic_subscription resources.
#
#   • CONSUMER LAMBDAS:
#     Deployed with placeholder code (replaced by CI/CD).  Each function
#     runs in the VPC to access RDS (invoice generator, audit logger).
#     The notification Lambda doesn't need VPC — it calls SES.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# SNS Topic — subscription-events
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_sns_topic" "subscription_events" {
  name = "${var.project}-${var.environment}-subscription-events"

  # Server-side encryption
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-subscription-events"
  })
}

# SNS topic policy — allow SQS subscriptions from this account
resource "aws_sns_topic_policy" "subscription_events" {
  arn    = aws_sns_topic.subscription_events.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowSQSSubscription"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sqs.amazonaws.com"]
    }

    actions   = ["sns:Subscribe", "sns:Receive"]
    resources = [aws_sns_topic.subscription_events.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowPublishFromAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.subscription_events.arn]
  }
}

data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────────────────── #
# Consumer definitions — each consumer gets: SQS queue, DLQ, Lambda, alarm
# ──────────────────────────────────────────────────────────────────────────── #

locals {
  consumers = {
    generate-invoice = {
      description    = "Generate invoice when subscription is created"
      timeout        = 30
      memory_size    = 256
      batch_size     = 1   # Process one subscription at a time (invoice is heavy)
      max_receive    = 5
      needs_vpc      = true
    }
    send-notification = {
      description    = "Send email notification on subscription creation"
      timeout        = 15
      memory_size    = 128
      batch_size     = 5   # Batch notifications for efficiency
      max_receive    = 3
      needs_vpc      = false  # Calls SES, not RDS
    }
    audit-log = {
      description    = "Write audit log entry for subscription events"
      timeout        = 15
      memory_size    = 128
      batch_size     = 10  # Batch audit writes for throughput
      max_receive    = 5
      needs_vpc      = true
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS Dead-Letter Queues (one per consumer)
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_sqs_queue" "dlq" {
  for_each = local.consumers

  name                      = "${var.project}-${var.environment}-${each.key}-dlq"
  message_retention_seconds = 1209600  # 14 days — time to investigate failures
  visibility_timeout_seconds = 60

  sqs_managed_sse_enabled = true

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}-dlq"
    Consumer = each.key
    Type     = "dead-letter-queue"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS Processing Queues (one per consumer)
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_sqs_queue" "processing" {
  for_each = local.consumers

  name = "${var.project}-${var.environment}-${each.key}"

  # Visibility timeout = 6× Lambda timeout (AWS best practice)
  # Prevents message from becoming visible while Lambda is still processing
  visibility_timeout_seconds = each.value.timeout * 6

  # Moderate retention — messages should be processed quickly or DLQ'd
  message_retention_seconds = 345600  # 4 days

  # Enable long polling to reduce empty receives and cost
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  # Dead-letter queue configuration
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive
  })

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}"
    Consumer = each.key
  })
}

# Allow the DLQ to receive messages from the processing queue
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.consumers

  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.processing[each.key].arn]
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS Queue Policies — Allow SNS to send messages
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_sqs_queue_policy" "allow_sns" {
  for_each = local.consumers

  queue_url = aws_sqs_queue.processing[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSNSPublish"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.processing[each.key].arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.subscription_events.arn
          }
        }
      }
    ]
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# SNS → SQS Subscriptions
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_sns_topic_subscription" "sqs" {
  for_each = local.consumers

  topic_arn            = aws_sns_topic.subscription_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.processing[each.key].arn
  raw_message_delivery = true  # Skip SNS envelope — cleaner for Lambda parsing
}

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Log Groups — one per consumer Lambda
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_log_group" "consumer" {
  for_each = local.consumers

  name              = "/aws/lambda/${var.project}-${var.environment}-${each.key}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}-logs"
    Consumer = each.key
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Consumer Lambda Functions
# ──────────────────────────────────────────────────────────────────────────── #

data "archive_file" "consumer_placeholder" {
  type        = "zip"
  output_path = "${path.module}/consumer_placeholder.zip"

  source {
    content  = <<-EOF
      exports.handler = async (event) => {
        console.log(JSON.stringify({ message: "Not implemented — deploy via CI/CD", records: event.Records?.length }));
        return { batchItemFailures: [] };
      };
    EOF
    filename = "index.js"
  }
}

resource "aws_lambda_function" "consumer" {
  for_each = local.consumers

  function_name = "${var.project}-${var.environment}-${each.key}"
  description   = each.value.description
  role          = var.lambda_execution_role_arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = each.value.timeout
  memory_size   = each.value.memory_size

  filename         = data.archive_file.consumer_placeholder.output_path
  source_code_hash = data.archive_file.consumer_placeholder.output_base64sha256

  # VPC configuration — only for consumers that need DB access
  dynamic "vpc_config" {
    for_each = each.value.needs_vpc ? [1] : []
    content {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [var.lambda_security_group_id]
    }
  }

  environment {
    variables = {
      ENVIRONMENT   = var.environment
      PROJECT       = var.project
      LOG_LEVEL     = var.environment == "prod" ? "WARN" : "DEBUG"
      DB_SECRET_ARN = var.db_secret_arn
      SNS_TOPIC_ARN = aws_sns_topic.subscription_events.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.consumer]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}"
    Consumer = each.key
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS → Lambda Event Source Mappings
# ──────────────────────────────────────────────────────────────────────────── #
# This connects each SQS queue to its consumer Lambda.
# `report_batch_item_failures` enables partial batch failure reporting —
# only failed messages are retried, not the entire batch.

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  for_each = local.consumers

  event_source_arn                   = aws_sqs_queue.processing[each.key].arn
  function_name                      = aws_lambda_function.consumer[each.key].arn
  batch_size                         = each.value.batch_size
  maximum_batching_window_in_seconds = 5  # Wait up to 5s to fill batch

  function_response_types = ["ReportBatchItemFailures"]

  # Scale up gradually to avoid overwhelming downstream services
  scaling_config {
    maximum_concurrency = var.environment == "prod" ? 50 : 5
  }

  depends_on = [aws_lambda_function.consumer]
}

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Alarms — Alert on non-empty DLQs
# ──────────────────────────────────────────────────────────────────────────── #
# Any message in a DLQ means all retries failed — this requires human
# investigation.  The alarm triggers after just 1 message.

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = local.consumers

  alarm_name          = "${var.project}-${var.environment}-${each.key}-dlq-messages"
  alarm_description   = "Messages in DLQ for ${each.key} — retries exhausted, investigate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  # In production, add: alarm_actions = [var.ops_sns_topic_arn]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}-dlq-alarm"
    Consumer = each.key
  })
}
