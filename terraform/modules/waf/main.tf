###############################################################################
# WAF Module — AWS WAF v2 for API Gateway Protection
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • WAFv2 Web ACL associate with the HTTP API Gateway stage ARN.
#     Note: HTTP APIs (API Gateway v2) require a REGIONAL Web ACL, not
#     CloudFront (CLOUDFRONT scope is for distributions only).
#
#   • Rule evaluation order uses priority numbers (lower = evaluated first):
#       1. IP reputation (block known bad actors — cheapest filter first)
#       2. Rate limiting per IP (stop brute-force / DDoS before rule eval)
#       3. AWS managed common rule set (OWASP Top 10 protections)
#       4. Known bad inputs (Log4Shell, SSRF patterns, etc.)
#       5. SQL injection protection (defense-in-depth for Aurora)
#       6. Geographic restrictions (optional — block entire countries)
#
#   • Rate-based rule uses IP as the aggregation key.  The default threshold
#     of 2000 requests per 5-minute window (≈6.7 req/s) is generous for a
#     billing API but stops automated abuse.  Per-tenant rate limiting should
#     be implemented at the application layer for finer granularity.
#
#   • All managed rule groups use COUNT override for evaluation period, then
#     switch to BLOCK once validated.  The `rule_action_overrides` parameter
#     controls this.  Set `managed_rules_action = "none"` for blocking mode
#     or `"count"` during evaluation.
#
#   • CloudWatch metrics are enabled per-rule for visibility into which rules
#     fire most frequently.  This drives tuning decisions (false positive
#     detection, threshold adjustments).
#
#   • WAF logging is configured to CloudWatch Logs.  WAF can also send to
#     S3 or Kinesis Firehose — CloudWatch is chosen for consistency with the
#     observability module and lower operational overhead in dev/staging.
#
#   • Sampled requests are enabled for debugging (visible in the AWS Console
#     WAF > Web ACLs > Sampled requests tab).
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# WAF v2 Web ACL
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_wafv2_web_acl" "api" {
  name        = "${var.project}-${var.environment}-api-waf"
  description = "WAF protection for ${var.project} HTTP API (${var.environment})"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # ---------- Rule 1: IP Reputation List ---------------------------------- #
  # Blocks requests from IPs known to be associated with bots, fraud, or
  # malicious activity.  Updated automatically by AWS Threat Intelligence.
  rule {
    name     = "aws-ip-reputation"
    priority = 1

    override_action {
      dynamic "none" {
        for_each = var.managed_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.managed_rules_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # ---------- Rule 2: Rate-Based (per-IP) -------------------------------- #
  # Throttles any single IP that exceeds the configured request threshold
  # within a 5-minute evaluation window.
  rule {
    name     = "rate-limit-per-ip"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_threshold
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # ---------- Rule 3: AWS Common Rule Set (OWASP Top 10) ------------------ #
  # Protects against common web exploits: XSS, path traversal, protocol
  # violations, etc.  Based on OWASP ModSecurity Core Rule Set (CRS).
  rule {
    name     = "aws-common-rules"
    priority = 3

    override_action {
      dynamic "none" {
        for_each = var.managed_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.managed_rules_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Exclude rules that commonly trigger false positives on JSON APIs
        dynamic "rule_action_override" {
          for_each = var.common_rules_excluded_rules
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # ---------- Rule 4: Known Bad Inputs ------------------------------------ #
  # Detects and blocks request patterns associated with exploitation of
  # vulnerabilities: Log4Shell (CVE-2021-44228), SSRF, etc.
  rule {
    name     = "aws-known-bad-inputs"
    priority = 4

    override_action {
      dynamic "none" {
        for_each = var.managed_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.managed_rules_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ---------- Rule 5: SQL Injection Protection ---------------------------- #
  # Defense-in-depth for the Aurora database layer.  Even though the app uses
  # parameterized queries, WAF catches SQLi in headers, query strings, and
  # URI paths that the app might not validate.
  rule {
    name     = "aws-sqli-rules"
    priority = 5

    override_action {
      dynamic "none" {
        for_each = var.managed_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.managed_rules_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-sqli-rules"
      sampled_requests_enabled   = true
    }
  }

  # ---------- Rule 6: Geographic Restrictions (optional) ------------------ #
  dynamic "rule" {
    for_each = length(var.blocked_country_codes) > 0 ? [1] : []

    content {
      name     = "geo-block"
      priority = 6

      action {
        block {}
      }

      statement {
        geo_match_statement {
          country_codes = var.blocked_country_codes
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.project}-${var.environment}-geo-block"
        sampled_requests_enabled   = true
      }
    }
  }

  # ---------- Web ACL visibility config ----------------------------------- #
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.environment}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-api-waf"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# WAF Association — Attach Web ACL to API Gateway Stage
# ──────────────────────────────────────────────────────────────────────────── #
# For HTTP API (API Gateway v2), the resource ARN is the stage ARN:
#   arn:aws:apigateway:{region}::/apis/{api-id}/stages/{stage-name}

resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = var.api_stage_arn
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}

# ──────────────────────────────────────────────────────────────────────────── #
# WAF Logging — CloudWatch Log Group
# ──────────────────────────────────────────────────────────────────────────── #
# WAF logging requires a log group name starting with "aws-waf-logs-".
# This is an AWS-enforced naming convention.

resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_logging ? 1 : 0

  # MUST start with "aws-waf-logs-" per AWS requirement
  name              = "aws-waf-logs-${var.project}-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "aws-waf-logs-${var.project}-${var.environment}"
  })
}

resource "aws_wafv2_web_acl_logging_configuration" "api" {
  count = var.enable_logging ? 1 : 0

  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
  resource_arn            = aws_wafv2_web_acl.api.arn

  # Optionally filter which requests are logged (reduce volume/cost)
  dynamic "redacted_fields" {
    for_each = var.redact_authorization_header ? [1] : []
    content {
      single_header {
        name = "authorization"
      }
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────── #
# CloudWatch Alarms — WAF Block Rate
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cloudwatch_metric_alarm" "waf_blocked_requests" {
  count = var.alarm_sns_topic_arn != "" ? 1 : 0

  alarm_name          = "${var.project}-${var.environment}-waf-blocked-high"
  alarm_description   = "WAF blocked request count exceeds threshold — possible attack or misconfiguration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = var.blocked_requests_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.api.name
    Region = var.aws_region
    Rule   = "ALL"
  }

  alarm_actions = [var.alarm_sns_topic_arn]
  ok_actions    = [var.alarm_sns_topic_arn]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-waf-blocked-alarm"
  })
}
