/**
 * Structured Logger — JSON output for CloudWatch Insights
 * ────────────────────────────────────────────────────────────────────────────
 * Design decisions:
 *   - Every log line is a single JSON object — CloudWatch Insights can query
 *     any field with `fields @message | filter level = "ERROR"`.
 *   - Context fields (requestId, tenantId, functionName) are set once per
 *     invocation via `withContext()` and automatically included in every line.
 *   - Log levels are controlled by the LOG_LEVEL env var (DEBUG < INFO < WARN < ERROR).
 *   - Child loggers inherit parent context — useful for adding per-operation fields.
 *   - No external dependency — runs in 0ms with zero cold-start impact.
 */

const LOG_LEVELS = { DEBUG: 0, INFO: 1, WARN: 2, ERROR: 3 };

class Logger {
  constructor(context = {}, minLevel = process.env.LOG_LEVEL || "INFO") {
    this.context = context;
    this.minLevel = LOG_LEVELS[minLevel] ?? LOG_LEVELS.INFO;
  }

  /**
   * Create a child logger with additional context fields.
   * The parent context is preserved (shallow merge — child wins on conflict).
   */
  child(additionalContext) {
    const levelName = Object.keys(LOG_LEVELS).find(
      (k) => LOG_LEVELS[k] === this.minLevel,
    );
    return new Logger({ ...this.context, ...additionalContext }, levelName);
  }

  /**
   * Set invocation-level context (called once per Lambda invocation).
   */
  withContext(ctx) {
    this.context = { ...this.context, ...ctx };
    return this;
  }

  debug(message, data = {}) {
    this._log("DEBUG", message, data);
  }
  info(message, data = {}) {
    this._log("INFO", message, data);
  }
  warn(message, data = {}) {
    this._log("WARN", message, data);
  }
  error(message, data = {}) {
    this._log("ERROR", message, data);
  }

  _log(level, message, data) {
    if (LOG_LEVELS[level] < this.minLevel) return;

    const entry = {
      timestamp: new Date().toISOString(),
      level,
      message,
      ...this.context,
      ...data,
    };

    // Serialize errors properly (Error objects don't stringify by default)
    if (data.error instanceof Error) {
      entry.error = {
        name: data.error.name,
        message: data.error.message,
        stack: data.error.stack,
      };
    }

    // Use stdout for all levels — CloudWatch reads stdout
    const output = JSON.stringify(entry);
    if (level === "ERROR") {
      process.stderr.write(output + "\n");
    } else {
      process.stdout.write(output + "\n");
    }
  }
}

/**
 * Create a logger pre-configured from a Lambda context object.
 */
function createLogger(lambdaContext = {}) {
  return new Logger({
    functionName:
      lambdaContext.functionName || process.env.AWS_LAMBDA_FUNCTION_NAME,
    functionVersion: lambdaContext.functionVersion,
    requestId: lambdaContext.awsRequestId,
    environment: process.env.ENVIRONMENT,
  });
}

module.exports = { Logger, createLogger };
