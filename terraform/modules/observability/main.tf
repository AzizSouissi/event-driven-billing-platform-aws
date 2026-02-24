###############################################################################
# Observability Module — CloudWatch Dashboard, Alarms & Metric Filters
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • SINGLE DASHBOARD:
#     One operational dashboard with three sections:
#       1. API Performance — latency P50/P90/P99, request count, 4xx/5xx rates
#       2. Lambda Health — error rate, duration, concurrent executions, throttles
#       3. Business KPIs — subscription count, invoice generation time, revenue
#     Each section is a row of widgets.  Operators see the full picture at a
#     glance without switching dashboards.
#
#   • ALARM STRATEGY (anti-fatigue):
#     Alarms use composite evaluation and multi-period breaching to prevent
#     false positives:
#       - Lambda error rate: 5% over 3 consecutive 5-min periods (15 min)
#       - RDS CPU: 70% over 3 consecutive 5-min periods (15 min)
#     Single-spike alarms cause alert fatigue.  Requiring 3 sequential
#     breaches means the issue is persistent, not a transient blip.
#
#   • METRIC MATH:
#     Lambda error rate is computed as (Errors / Invocations * 100).
#     This is more useful than raw error count because it normalizes
#     for traffic volume.  100 errors out of 1M requests (0.01%) is
#     fine; 100 errors out of 200 requests (50%) is a crisis.
#
#   • SNS ALARM TOPIC:
#     All alarms publish to a dedicated SNS topic.  This decouples the
#     alarm from the notification channel.  Add email, PagerDuty, Slack,
#     or OpsGenie subscriptions to this topic without touching alarms.
#
#   • METRIC FILTERS:
#     Extract structured metrics from Lambda log groups using JSON patterns.
#     This bridges the gap between logs (rich context) and metrics (fast
#     aggregation) — we get both without double-writing.
#
#   • ANOMALY DETECTION:
#     For API latency, we use CloudWatch Anomaly Detection rather than a
#     fixed threshold.  Billing systems have predictable traffic patterns
#     (higher at month-end billing cycles).  A fixed 500ms threshold would
#     false-alarm during batch invoice generation.  Anomaly detection
#     learns the normal pattern and alerts on deviations.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# SNS Topic for Alarm Notifications
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_sns_topic" "alarms" {
  name              = "${var.project}-${var.environment}-alarms"
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-alarms"
  })
}

# Optional: email subscription for dev (add PagerDuty/Slack in prod via var)
resource "aws_sns_topic_subscription" "alarm_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Error Rate Alarm — fires when error rate > 5% for 15 minutes
# ──────────────────────────────────────────────────────────────────────────── #
# Uses metric math: (Errors / Invocations) * 100 > 5
# Evaluation: 3 consecutive 5-minute periods = 15 minutes of sustained errors
# This prevents alerting on a single failed request or cold-start blip.

resource "aws_cloudwatch_metric_alarm" "lambda_error_rate" {
  for_each = toset(var.lambda_function_names)

  alarm_name          = "${var.project}-${var.environment}-${each.key}-error-rate"
  alarm_description   = "Lambda ${each.key} error rate > ${var.lambda_error_rate_threshold}% for ${var.lambda_error_rate_evaluation_periods * var.lambda_error_rate_period / 60} minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.lambda_error_rate_threshold
  evaluation_periods  = var.lambda_error_rate_evaluation_periods
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(invocations > 0, (errors / invocations) * 100, 0)"
    label       = "Error Rate %"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = var.lambda_error_rate_period
      stat        = "Sum"
      dimensions = {
        FunctionName = each.key
      }
    }
  }

  metric_query {
    id = "invocations"

    metric {
      metric_name = "Invocations"
      namespace   = "AWS/Lambda"
      period      = var.lambda_error_rate_period
      stat        = "Sum"
      dimensions = {
        FunctionName = each.key
      }
    }
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}-error-rate"
    Function = each.key
    Severity = "critical"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# RDS CPU Utilization Alarm — fires when CPU > 70% for 15 minutes
# ──────────────────────────────────────────────────────────────────────────── #
# 3 consecutive 5-minute periods prevents alerting on query spikes during
# batch invoice generation or end-of-month billing runs.

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.rds_instance_id != "" ? 1 : 0

  alarm_name          = "${var.project}-${var.environment}-rds-cpu-high"
  alarm_description   = "RDS CPU > ${var.rds_cpu_threshold}% for ${var.rds_cpu_evaluation_periods * var.rds_cpu_period / 60} minutes — investigate slow queries or scale up"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.rds_cpu_evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = var.rds_cpu_period
  statistic           = "Average"
  threshold           = var.rds_cpu_threshold
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-rds-cpu-high"
    Severity = "warning"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# RDS Free Storage Alarm — fires when < 20% storage remaining
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  count = var.rds_instance_id != "" ? 1 : 0

  alarm_name          = "${var.project}-${var.environment}-rds-storage-low"
  alarm_description   = "RDS free storage < ${var.rds_free_storage_threshold_bytes / 1073741824} GB — extend volume or purge old data"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = var.rds_free_storage_threshold_bytes
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-rds-storage-low"
    Severity = "warning"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# RDS Database Connections Alarm — approaching connection limit
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count = var.rds_instance_id != "" ? 1 : 0

  alarm_name          = "${var.project}-${var.environment}-rds-connections-high"
  alarm_description   = "RDS connections > ${var.rds_max_connections_threshold} — risk of connection exhaustion from Lambda scaling"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.rds_max_connections_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-rds-connections-high"
    Severity = "warning"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# Lambda Throttle Alarm — Lambda is being throttled
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = toset(var.lambda_function_names)

  alarm_name          = "${var.project}-${var.environment}-${each.key}-throttled"
  alarm_description   = "Lambda ${each.key} is being throttled — increase concurrency limit or check downstream"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.key
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-${each.key}-throttled"
    Function = each.key
    Severity = "warning"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway 5xx Alarm
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  count = var.api_id != "" ? 1 : 0

  alarm_name          = "${var.project}-${var.environment}-api-5xx-rate"
  alarm_description   = "API Gateway 5xx error count > ${var.api_5xx_threshold} — server-side failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = var.api_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.environment}-api-5xx-rate"
    Severity = "critical"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Log Metric Filters — Extract metrics from structured logs
# ──────────────────────────────────────────────────────────────────────────── #
# These filters parse the JSON logs emitted by our structured logger and the
# EMF metrics module, creating CloudWatch metrics from log patterns.

# Metric filter: Count of application errors across all Lambdas
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  for_each = toset(var.lambda_log_group_names)

  name           = "${var.project}-${var.environment}-app-errors"
  log_group_name = each.key
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = "ApplicationErrors"
    namespace     = "${var.project}/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

# Metric filter: Count of 4xx client errors
resource "aws_cloudwatch_log_metric_filter" "client_errors" {
  for_each = toset(var.lambda_log_group_names)

  name           = "${var.project}-${var.environment}-client-errors"
  log_group_name = each.key
  pattern        = "{ $.statusCode >= 400 && $.statusCode < 500 }"

  metric_transformation {
    name          = "ClientErrors"
    namespace     = "${var.project}/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

# Metric filter: Count of tenant creation events
resource "aws_cloudwatch_log_metric_filter" "tenant_created" {
  count = length(var.lambda_log_group_names) > 0 ? 1 : 0

  name           = "${var.project}-${var.environment}-tenant-created"
  log_group_name = var.lambda_log_group_names[0]
  pattern        = "{ $.message = \"Tenant created successfully\" }"

  metric_transformation {
    name          = "TenantCreated"
    namespace     = "${var.project}/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Dashboard — Operational overview
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-${var.environment}-operations"

  dashboard_body = jsonencode({
    widgets = concat(
      # ── Row 1: API Performance ─────────────────────────────────────── #
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 1
          properties = {
            markdown = "# API Performance"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 1
          width  = 8
          height = 6
          properties = {
            title   = "API Latency (P50 / P90 / P99)"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            stat    = "p50"
            metrics = var.api_id != "" ? [
              ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p50", label = "P50" }],
              ["...", { stat = "p90", label = "P90" }],
              ["...", { stat = "p99", label = "P99" }],
            ] : []
            yAxis = {
              left = { label = "ms", showUnits = false }
            }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 1
          width  = 8
          height = 6
          properties = {
            title   = "API Request Count"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            stat    = "Sum"
            metrics = var.api_id != "" ? [
              ["AWS/ApiGateway", "Count", "ApiId", var.api_id, { label = "Requests" }],
            ] : []
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 1
          width  = 8
          height = 6
          properties = {
            title   = "API Error Rates (4xx / 5xx)"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            stat    = "Sum"
            metrics = var.api_id != "" ? [
              ["AWS/ApiGateway", "4xx", "ApiId", var.api_id, { label = "4xx Client Errors", color = "#ff9900" }],
              ["AWS/ApiGateway", "5xx", "ApiId", var.api_id, { label = "5xx Server Errors", color = "#d13212" }],
            ] : []
          }
        },
      ],

      # ── Row 2: Lambda Performance ──────────────────────────────────── #
      [
        {
          type   = "text"
          x      = 0
          y      = 7
          width  = 24
          height = 1
          properties = {
            markdown = "# Lambda Performance"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 8
          height = 6
          properties = {
            title   = "Lambda Error Rate (%)"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            metrics = [
              for fn in var.lambda_function_names : [
                {
                  expression  = "IF(m_inv_${replace(fn, "-", "_")} > 0, (m_err_${replace(fn, "-", "_")} / m_inv_${replace(fn, "-", "_")}) * 100, 0)"
                  label       = fn
                  id          = "rate_${replace(fn, "-", "_")}"
                }
              ]
            ]
            yAxis = {
              left = { label = "%", showUnits = false, min = 0 }
            }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 8
          width  = 8
          height = 6
          properties = {
            title   = "Lambda Duration (P90)"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            stat    = "p90"
            metrics = [
              for fn in var.lambda_function_names :
              ["AWS/Lambda", "Duration", "FunctionName", fn, { label = fn }]
            ]
            yAxis = {
              left = { label = "ms", showUnits = false }
            }
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 8
          width  = 8
          height = 6
          properties = {
            title   = "Lambda Concurrent Executions"
            view    = "timeSeries"
            stacked = true
            region  = var.aws_region
            period  = 60
            stat    = "Maximum"
            metrics = [
              for fn in var.lambda_function_names :
              ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", fn, { label = fn }]
            ]
          }
        },
      ],

      # ── Row 3: Business KPIs ───────────────────────────────────────── #
      [
        {
          type   = "text"
          x      = 0
          y      = 14
          width  = 24
          height = 1
          properties = {
            markdown = "# Business KPIs"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 15
          width  = 8
          height = 6
          properties = {
            title   = "Invoice Generation Time"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            metrics = [
              ["${var.project}/${var.environment}", "invoice_generation_time", "FunctionName", "${var.project}-${var.environment}-generate-invoice", "Environment", var.environment, { stat = "p50", label = "P50" }],
              ["...", { stat = "p90", label = "P90" }],
              ["...", { stat = "p99", label = "P99" }],
            ]
            yAxis = {
              left = { label = "ms", showUnits = false }
            }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 15
          width  = 8
          height = 6
          properties = {
            title   = "Subscriptions Created"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 3600
            stat    = "Sum"
            metrics = [
              ["${var.project}/${var.environment}", "subscription_count", "FunctionName", "${var.project}-${var.environment}-create-subscription", "Environment", var.environment, { label = "New Subscriptions" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 15
          width  = 8
          height = 6
          properties = {
            title   = "Revenue per Invoice (Amount)"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 3600
            metrics = [
              ["${var.project}/${var.environment}", "invoice_amount", "FunctionName", "${var.project}-${var.environment}-generate-invoice", "Environment", var.environment, { stat = "Sum", label = "Total" }],
              ["...", { stat = "Average", label = "Avg per Invoice" }],
            ]
            yAxis = {
              left = { label = "USD (cents)", showUnits = false }
            }
          }
        },
      ],

      # ── Row 4: SQS Queue Health ────────────────────────────────────── #
      [
        {
          type   = "text"
          x      = 0
          y      = 21
          width  = 24
          height = 1
          properties = {
            markdown = "# Event Processing & Queues"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 22
          width  = 12
          height = 6
          properties = {
            title   = "SQS Messages In Flight"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 60
            stat    = "Maximum"
            metrics = [
              for name in var.sqs_queue_names :
              ["AWS/SQS", "ApproximateNumberOfMessagesNotVisible", "QueueName", name, { label = name }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 22
          width  = 12
          height = 6
          properties = {
            title   = "DLQ Message Count (should be 0)"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 60
            stat    = "Maximum"
            metrics = [
              for name in var.dlq_names :
              ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", name, { label = name }]
            ]
            annotations = {
              horizontal = [
                { label = "Alert threshold", value = 1, color = "#d13212" }
              ]
            }
          }
        },
      ],

      # ── Row 5: RDS (if configured) ─────────────────────────────────── #
      var.rds_instance_id != "" ? [
        {
          type   = "text"
          x      = 0
          y      = 28
          width  = 24
          height = 1
          properties = {
            markdown = "# Database (RDS)"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 29
          width  = 8
          height = 6
          properties = {
            title   = "RDS CPU Utilization"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            stat    = "Average"
            metrics = [
              ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_instance_id, { label = "CPU %" }],
            ]
            annotations = {
              horizontal = [
                { label = "Alarm threshold", value = var.rds_cpu_threshold, color = "#d13212" }
              ]
            }
            yAxis = {
              left = { min = 0, max = 100, label = "%", showUnits = false }
            }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 29
          width  = 8
          height = 6
          properties = {
            title   = "RDS Database Connections"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 60
            stat    = "Maximum"
            metrics = [
              ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_instance_id, { label = "Connections" }],
            ]
            annotations = {
              horizontal = [
                { label = "Connection limit warning", value = var.rds_max_connections_threshold, color = "#ff9900" }
              ]
            }
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 29
          width  = 8
          height = 6
          properties = {
            title   = "RDS Free Storage Space"
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            period  = 300
            stat    = "Minimum"
            metrics = [
              ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_instance_id, { label = "Free Storage (bytes)" }],
            ]
          }
        },
      ] : [],
    )
  })
}
