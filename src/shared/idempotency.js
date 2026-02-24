/**
 * Idempotency Guard — Prevents Duplicate Processing of SQS Messages
 * ────────────────────────────────────────────────────────────────────────────
 * Design decisions:
 *
 *   • WHY IDEMPOTENCY MATTERS:
 *     SQS guarantees "at-least-once" delivery.  A message CAN be delivered
 *     twice if:
 *       a) Lambda crashes after processing but before deleting the message
 *       b) Visibility timeout expires during a slow invocation
 *       c) SQS internal retry delivers a duplicate
 *     Without idempotency, we'd generate duplicate invoices, send duplicate
 *     emails, or create duplicate audit entries.
 *
 *   • IMPLEMENTATION:
 *     Uses a PostgreSQL `processed_events` table with a UNIQUE constraint
 *     on `idempotency_key`.  Before processing, the handler attempts an
 *     INSERT.  If the key already exists (duplicate), we skip processing
 *     and return success.
 *
 *     PostgreSQL was chosen over DynamoDB because:
 *       a) We already have an RDS connection pool — no extra service
 *       b) The check + insert is transactional with the business logic
 *       c) No additional cost or IAM complexity
 *
 *   • IDEMPOTENCY KEY FORMAT:
 *     `{eventType}:{subscriptionId}:{messageId}`
 *     The SQS messageId ensures uniqueness even if the same subscription
 *     event is published twice.  The eventType prefix prevents collision
 *     across consumer types.
 *
 *   • TTL:
 *     Processed events older than 7 days are eligible for cleanup.
 *     A scheduled job (not included) can DELETE WHERE processed_at < NOW() - 7d.
 *     This prevents unbounded table growth.
 */

const { querySystem } = require("./db");
const { createLogger } = require("./logger");

const logger = createLogger();

/**
 * Check if an event has already been processed.
 * If not, mark it as processing.  Returns { alreadyProcessed: boolean }.
 *
 * @param {string} idempotencyKey - Unique key for this processing attempt
 * @param {string} consumerName   - Name of the consumer (e.g., "generate-invoice")
 * @returns {Promise<{ alreadyProcessed: boolean }>}
 */
async function acquireIdempotencyLock(idempotencyKey, consumerName) {
  try {
    await querySystem(
      `INSERT INTO processed_events (idempotency_key, consumer, status, processed_at)
       VALUES ($1, $2, 'processing', NOW())`,
      [idempotencyKey, consumerName],
    );
    return { alreadyProcessed: false };
  } catch (err) {
    // Unique constraint violation = already processed
    if (err.code === "23505") {
      logger.info("Duplicate event detected — skipping", {
        idempotencyKey,
        consumerName,
      });
      return { alreadyProcessed: true };
    }
    throw err;
  }
}

/**
 * Mark an event as successfully processed.
 */
async function markProcessed(idempotencyKey) {
  await querySystem(
    `UPDATE processed_events SET status = 'completed', completed_at = NOW()
     WHERE idempotency_key = $1`,
    [idempotencyKey],
  );
}

/**
 * Release the lock on failure so the message can be retried.
 * Deletes the row so the next attempt can re-acquire the lock.
 */
async function releaseIdempotencyLock(idempotencyKey) {
  await querySystem(
    `DELETE FROM processed_events WHERE idempotency_key = $1 AND status = 'processing'`,
    [idempotencyKey],
  );
}

module.exports = {
  acquireIdempotencyLock,
  markProcessed,
  releaseIdempotencyLock,
};
