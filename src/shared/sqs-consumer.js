/**
 * SQS Consumer Middleware — Batch processing with idempotency and partial failures
 * ────────────────────────────────────────────────────────────────────────────
 * Design decisions:
 *
 *   • PARTIAL BATCH FAILURE:
 *     Lambda receives a batch of SQS messages.  If one fails, we don't want
 *     to retry the entire batch — only the failed message.  The Lambda event
 *     source mapping is configured with `ReportBatchItemFailures`.
 *     This middleware returns `{ batchItemFailures: [...] }` containing
 *     only the messageIds that failed.
 *
 *   • IDEMPOTENCY:
 *     Each message is checked against the `processed_events` table before
 *     processing.  If already processed (duplicate delivery), we skip it
 *     and report success.  On failure, the idempotency lock is released
 *     so the retry can re-process.
 *
 *   • STRUCTURED LOGGING:
 *     Every message gets a child logger with messageId, idempotencyKey,
 *     and consumer name for full traceability.
 *
 *   • SNS MESSAGE PARSING:
 *     With `raw_message_delivery = true` on the SNS subscription, the SQS
 *     message body IS the raw event payload (no SNS envelope).
 */

const { createLogger } = require("./logger");
const {
  acquireIdempotencyLock,
  markProcessed,
  releaseIdempotencyLock,
} = require("./idempotency");

/**
 * Wrap an SQS consumer handler with batch processing, idempotency, and error handling.
 *
 * @param {string} consumerName - e.g., "generate-invoice"
 * @param {function} processMessage - async (parsedBody, { messageId, logger }) => void
 * @returns {function} Lambda handler
 */
function withSqsConsumer(consumerName, processMessage) {
  return async (event, context) => {
    const logger = createLogger(context);
    const batchItemFailures = [];

    logger.info("Processing SQS batch", {
      consumer: consumerName,
      batchSize: event.Records.length,
    });

    for (const record of event.Records) {
      const messageId = record.messageId;
      const msgLogger = logger.child({ messageId, consumer: consumerName });

      try {
        // ── Parse message body ────────────────────────────────────────── //
        const body = JSON.parse(record.body);
        const idempotencyKey = `${consumerName}:${body.subscriptionId || body.id}:${messageId}`;

        msgLogger.info("Processing message", {
          idempotencyKey,
          eventType: body.eventType,
        });

        // ── Idempotency check ─────────────────────────────────────────── //
        const { alreadyProcessed } = await acquireIdempotencyLock(
          idempotencyKey,
          consumerName,
        );

        if (alreadyProcessed) {
          msgLogger.info("Message already processed — skipping");
          continue; // Skip but report success (don't add to failures)
        }

        // ── Process the message ───────────────────────────────────────── //
        await processMessage(body, { messageId, logger: msgLogger, record });

        // ── Mark as completed ─────────────────────────────────────────── //
        await markProcessed(idempotencyKey);
        msgLogger.info("Message processed successfully");
      } catch (err) {
        msgLogger.error("Failed to process message", { error: err });

        // Release idempotency lock so retry can re-process
        try {
          const body = JSON.parse(record.body);
          const idempotencyKey = `${consumerName}:${body.subscriptionId || body.id}:${messageId}`;
          await releaseIdempotencyLock(idempotencyKey);
        } catch (releaseErr) {
          msgLogger.error("Failed to release idempotency lock", {
            error: releaseErr,
          });
        }

        // Report this message as failed — SQS will retry it
        batchItemFailures.push({ itemIdentifier: messageId });
      }
    }

    logger.info("Batch processing complete", {
      consumer: consumerName,
      total: event.Records.length,
      failed: batchItemFailures.length,
    });

    return { batchItemFailures };
  };
}

module.exports = { withSqsConsumer };
