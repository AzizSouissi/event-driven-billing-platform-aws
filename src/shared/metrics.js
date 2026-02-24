/**
 * Custom CloudWatch Metrics — Embedded Metric Format (EMF)
 * ────────────────────────────────────────────────────────────────────────────
 * Design decisions:
 *
 *   • EMBEDDED METRIC FORMAT (EMF):
 *     Instead of calling the CloudWatch PutMetricData API (which adds ~50ms
 *     latency per call and costs $0.01 per 1,000 API requests), we use EMF.
 *     EMF writes a specially-structured JSON line to stdout.  CloudWatch Logs
 *     automatically extracts it as a metric — zero API calls, zero latency
 *     impact, and it's FREE (you only pay for log ingestion, which you're
 *     already paying for).
 *
 *   • NAMESPACE:
 *     All custom metrics go under "BillingPlatform/{environment}".
 *     This separates dev/staging/prod metrics and avoids polluting the
 *     default AWS namespaces.
 *
 *   • DIMENSIONS:
 *     Every metric includes `FunctionName` and `Environment` dimensions.
 *     Business metrics add `TenantId` where applicable — this enables
 *     per-tenant dashboards without a CloudWatch Metrics API call.
 *
 *   • HIGH-RESOLUTION METRICS:
 *     StorageResolution = 1 (1-second resolution) for latency metrics.
 *     Standard resolution (60s) for counters like subscription_count.
 *     High-resolution costs ~$0.30/metric/month extra but is crucial
 *     for latency SLIs.
 *
 *   • NO EXTERNAL DEPENDENCY:
 *     EMF is just a JSON structure written to stdout.  No SDK needed.
 *     This means zero cold-start impact and no additional package size.
 *
 * Reference: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
 */

const NAMESPACE = `BillingPlatform/${process.env.ENVIRONMENT || "dev"}`;

/**
 * Flush a single EMF metric line to stdout.
 *
 * @param {string} metricName   - e.g., "invoice_generation_time"
 * @param {number} value        - The metric value
 * @param {string} unit         - CloudWatch unit: Milliseconds, Count, None, etc.
 * @param {Object} dimensions   - Additional dimensions beyond defaults
 * @param {Object} properties   - Extra searchable properties (not dimensions)
 * @param {number} storageResolution - 1 = high-res (1s), 60 = standard
 */
function putMetric(
  metricName,
  value,
  unit = "None",
  dimensions = {},
  properties = {},
  storageResolution = 60,
) {
  const allDimensions = {
    FunctionName: process.env.AWS_LAMBDA_FUNCTION_NAME || "unknown",
    Environment: process.env.ENVIRONMENT || "dev",
    ...dimensions,
  };

  // Build dimension keys array (CloudWatch requires this)
  const dimensionKeys = Object.keys(allDimensions);

  const emfEntry = {
    // EMF metadata — CloudWatch detects this and extracts the metric
    _aws: {
      Timestamp: Date.now(),
      CloudWatchMetrics: [
        {
          Namespace: NAMESPACE,
          Dimensions: [dimensionKeys],
          Metrics: [
            {
              Name: metricName,
              Unit: unit,
              StorageResolution: storageResolution,
            },
          ],
        },
      ],
    },
    // Dimension values
    ...allDimensions,
    // The metric value itself
    [metricName]: value,
    // Extra searchable properties — appear in Logs Insights but not as dimensions
    ...properties,
  };

  process.stdout.write(JSON.stringify(emfEntry) + "\n");
}

/**
 * Record a latency measurement with high resolution.
 *
 * @param {string} operation   - e.g., "invoice_generation", "db_query"
 * @param {number} durationMs  - Duration in milliseconds
 * @param {Object} dimensions  - Additional dimensions
 * @param {Object} properties  - Extra searchable properties
 */
function recordLatency(
  operation,
  durationMs,
  dimensions = {},
  properties = {},
) {
  putMetric(
    `${operation}_time`,
    durationMs,
    "Milliseconds",
    dimensions,
    properties,
    1, // High-resolution for latency
  );
}

/**
 * Increment a counter metric.
 *
 * @param {string} metricName  - e.g., "subscription_count", "invoice_count"
 * @param {number} count       - How many to increment by (default: 1)
 * @param {Object} dimensions  - Additional dimensions
 * @param {Object} properties  - Extra searchable properties
 */
function incrementCounter(
  metricName,
  count = 1,
  dimensions = {},
  properties = {},
) {
  putMetric(metricName, count, "Count", dimensions, properties, 60);
}

/**
 * Record a business KPI metric.
 *
 * @param {string} kpiName     - e.g., "revenue", "active_subscriptions"
 * @param {number} value       - The KPI value
 * @param {string} unit        - CloudWatch unit
 * @param {Object} dimensions  - Additional dimensions (tenantId, planId, etc.)
 */
function recordBusinessMetric(kpiName, value, unit = "Count", dimensions = {}) {
  putMetric(kpiName, value, unit, dimensions, {}, 60);
}

/**
 * Timer utility — returns a function that, when called, records the elapsed time.
 *
 * Usage:
 *   const stopTimer = startTimer("invoice_generation", { tenantId: "..." });
 *   // ... do work ...
 *   const durationMs = stopTimer();  // Records metric + returns duration
 */
function startTimer(operation, dimensions = {}, properties = {}) {
  const start = process.hrtime.bigint();

  return function stop() {
    const elapsed = Number(process.hrtime.bigint() - start) / 1_000_000; // ns → ms
    recordLatency(operation, elapsed, dimensions, properties);
    return elapsed;
  };
}

module.exports = {
  putMetric,
  recordLatency,
  incrementCounter,
  recordBusinessMetric,
  startTimer,
  NAMESPACE,
};
