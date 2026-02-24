/**
 * DLQ Reprocessor — Replay Failed Messages from Dead-Letter Queues
 * ────────────────────────────────────────────────────────────────────────────
 * Design decisions:
 *
 *   • PURPOSE:  When a consumer Lambda exhausts all retries, the message
 *     lands in a Dead-Letter Queue (DLQ).  This Lambda reads messages from
 *     a DLQ and sends them back to the original processing queue for
 *     another round of attempts.
 *
 *   • INVOCATION: Designed to be triggered manually (console/CLI) or on a
 *     schedule (CloudWatch Events rule).  NOT triggered by SQS event source
 *     mapping — operators decide WHEN to replay after fixing the root cause.
 *
 *   • INPUT: The event payload specifies which DLQ to drain and which
 *     processing queue to send messages to:
 *       {
 *         "dlqUrl": "https://sqs.../billing-platform-dev-generate-invoice-dlq",
 *         "targetQueueUrl": "https://sqs.../billing-platform-dev-generate-invoice",
 *         "maxMessages": 100  // optional, default = all
 *       }
 *
 *   • BATCH PROCESSING:  Reads up to 10 messages at a time from the DLQ
 *     (SQS maximum), sends them to the target queue, then deletes them
 *     from the DLQ.  Loops until the DLQ is empty or maxMessages is reached.
 *
 *   • IDEMPOTENCY:  The original message body and attributes are preserved.
 *     If the target consumer is idempotent (it should be), replaying is safe.
 *
 *   • ERROR HANDLING:  If a send fails, the message stays in the DLQ
 *     (not deleted).  The function reports partial success via the response.
 *
 *   • SAFETY:  A `maxMessages` cap prevents runaway reprocessing.  Default
 *     is unlimited (process all), but operators can set a lower cap.
 *
 *   • AUDIT TRAIL:  Every replay batch is logged with message IDs, counts,
 *     and any failures — queryable via CloudWatch Insights.
 */

const {
  SQSClient,
  ReceiveMessageCommand,
  SendMessageCommand,
  DeleteMessageCommand,
  GetQueueAttributesCommand,
} = require("@aws-sdk/client-sqs");
const { createLogger } = require("../../shared/logger");

const logger = createLogger();
const sqs = new SQSClient({ region: process.env.AWS_REGION || "us-east-1" });

/**
 * @param {Object} event
 * @param {string} event.dlqUrl - SQS DLQ URL to read from
 * @param {string} event.targetQueueUrl - SQS processing queue URL to send to
 * @param {number} [event.maxMessages] - Max messages to replay (default: all)
 */
exports.handler = async (event, context) => {
  logger.withContext({
    requestId: context.awsRequestId,
    functionName: context.functionName,
  });

  const { dlqUrl, targetQueueUrl, maxMessages } = event;

  // ── Validate input ──────────────────────────────────────────────────── //
  if (!dlqUrl || !targetQueueUrl) {
    const error = "Missing required fields: dlqUrl and targetQueueUrl";
    logger.error(error, { event });
    return {
      statusCode: 400,
      body: {
        error,
        usage: {
          dlqUrl: "https://sqs.../queue-dlq",
          targetQueueUrl: "https://sqs.../queue",
          maxMessages: 100,
        },
      },
    };
  }

  logger.info("Starting DLQ reprocessing", {
    dlqUrl,
    targetQueueUrl,
    maxMessages: maxMessages || "unlimited",
  });

  // ── Get approximate DLQ depth for logging ───────────────────────────── //
  let approximateMessageCount = "unknown";
  try {
    const attrs = await sqs.send(
      new GetQueueAttributesCommand({
        QueueUrl: dlqUrl,
        AttributeNames: ["ApproximateNumberOfMessages"],
      }),
    );
    approximateMessageCount =
      attrs.Attributes?.ApproximateNumberOfMessages || "0";
    logger.info("DLQ depth", { approximateMessageCount });
  } catch (err) {
    logger.warn("Could not get DLQ depth", { error: err });
  }

  let totalProcessed = 0;
  let totalFailed = 0;
  let totalDeleted = 0;
  const limit = maxMessages || Infinity;

  // ── Process DLQ in batches ──────────────────────────────────────────── //
  while (totalProcessed < limit) {
    const batchSize = Math.min(10, limit - totalProcessed);

    // Receive messages from DLQ
    const receiveResponse = await sqs.send(
      new ReceiveMessageCommand({
        QueueUrl: dlqUrl,
        MaxNumberOfMessages: batchSize,
        WaitTimeSeconds: 1, // Short poll — we want to exit quickly if empty
        MessageAttributeNames: ["All"],
        AttributeNames: ["All"],
      }),
    );

    const messages = receiveResponse.Messages || [];
    if (messages.length === 0) {
      logger.info("DLQ is empty — reprocessing complete", {
        totalProcessed,
        totalFailed,
        totalDeleted,
      });
      break;
    }

    logger.info("Processing DLQ batch", {
      batchSize: messages.length,
      totalProcessedSoFar: totalProcessed,
    });

    // Process each message: send to target, then delete from DLQ
    for (const message of messages) {
      try {
        // Re-send to the processing queue with original body and attributes
        await sqs.send(
          new SendMessageCommand({
            QueueUrl: targetQueueUrl,
            MessageBody: message.Body,
            MessageAttributes: message.MessageAttributes || {},
          }),
        );

        // Delete from DLQ only after successful send
        await sqs.send(
          new DeleteMessageCommand({
            QueueUrl: dlqUrl,
            ReceiptHandle: message.ReceiptHandle,
          }),
        );

        totalDeleted++;
        totalProcessed++;

        logger.debug("Message replayed successfully", {
          messageId: message.MessageId,
        });
      } catch (err) {
        totalFailed++;
        totalProcessed++;

        logger.error("Failed to replay message", {
          messageId: message.MessageId,
          error: err,
        });
        // Message stays in DLQ — will be picked up on next invocation
      }
    }
  }

  const summary = {
    dlqUrl,
    targetQueueUrl,
    approximateMessageCount,
    totalProcessed,
    totalReplayed: totalDeleted,
    totalFailed,
  };

  logger.info("DLQ reprocessing complete", summary);

  return {
    statusCode: 200,
    body: summary,
  };
};
