# ──────────────────────────────────────────────────────────────────────────── #
# SNS
# ──────────────────────────────────────────────────────────────────────────── #

output "sns_topic_arn" {
  description = "ARN of the subscription-events SNS topic (publish target)"
  value       = aws_sns_topic.subscription_events.arn
}

output "sns_topic_name" {
  description = "Name of the subscription-events SNS topic"
  value       = aws_sns_topic.subscription_events.name
}

# ──────────────────────────────────────────────────────────────────────────── #
# SQS Queues
# ──────────────────────────────────────────────────────────────────────────── #

output "processing_queue_arns" {
  description = "Map of consumer name → SQS processing queue ARN"
  value       = { for k, v in aws_sqs_queue.processing : k => v.arn }
}

output "processing_queue_urls" {
  description = "Map of consumer name → SQS processing queue URL"
  value       = { for k, v in aws_sqs_queue.processing : k => v.id }
}

output "dlq_arns" {
  description = "Map of consumer name → DLQ ARN"
  value       = { for k, v in aws_sqs_queue.dlq : k => v.arn }
}

# ──────────────────────────────────────────────────────────────────────────── #
# Consumer Lambdas
# ──────────────────────────────────────────────────────────────────────────── #

output "consumer_function_arns" {
  description = "Map of consumer name → Lambda function ARN"
  value       = { for k, v in aws_lambda_function.consumer : k => v.arn }
}

output "consumer_function_names" {
  description = "Map of consumer name → Lambda function name"
  value       = { for k, v in aws_lambda_function.consumer : k => v.function_name }
}

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Alarms
# ──────────────────────────────────────────────────────────────────────────── #

output "dlq_alarm_arns" {
  description = "Map of consumer name → DLQ CloudWatch alarm ARN"
  value       = { for k, v in aws_cloudwatch_metric_alarm.dlq_not_empty : k => v.arn }
}
