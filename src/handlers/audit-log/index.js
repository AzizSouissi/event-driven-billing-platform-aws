/**
 * audit-log — SQS Consumer
 * ────────────────────────────────────────────────────────────────────────────
 * Triggered when a subscription is created.  Writes a tamper-evident audit
 * trail entry to the `audit_logs` table.
 *
 * Flow:
 *   1. Receives "subscription.created" event from SQS (via SNS fan-out).
 *   2. Idempotency middleware prevents duplicate audit entries.
 *   3. Inserts a structured audit record with the full event payload.
 *   4. Reports success/failure.
 *
 * Design decisions:
 *   • APPEND-ONLY TABLE: Audit logs are INSERT-only.  No UPDATE or DELETE
 *     operations are permitted (enforced by a DO INSTEAD NOTHING rule on
 *     UPDATE/DELETE in the migration, or by application convention).
 *   • FULL EVENT SNAPSHOT: The entire event payload is stored in a JSONB
 *     column.  This preserves the exact data at the time of the event,
 *     even if the subscription is later modified.
 *   • BATCH PROCESSING: This consumer uses batch_size=10 for throughput.
 *     Audit writes are lightweight (single INSERT) and benefit from batching.
 *   • SYSTEM QUERY: Uses `querySystem()` instead of `queryWithTenant()`
 *     because audit logs may need cross-tenant reporting by admins.
 *     Access control is enforced at the application layer, not RLS.
 */

const { v4: uuidv4 } = require("uuid");
const { querySystem } = require("../../shared/db");
const { withSqsConsumer } = require("../../shared/sqs-consumer");

async function processAuditLog(body, { messageId, logger }) {
  const {
    eventType,
    tenantId,
    subscriptionId,
    userId,
    planId,
    billingCycle,
    amount,
    timestamp,
  } = body;

  logger.info("Writing audit log entry", {
    eventType,
    tenantId,
    subscriptionId,
  });

  const auditId = uuidv4();

  await querySystem(
    `INSERT INTO audit_logs
       (id, tenant_id, event_type, entity_type, entity_id, actor_id,
        payload, source_message_id, created_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
    [
      auditId,
      tenantId,
      eventType || "subscription.created",
      "subscription",
      subscriptionId,
      userId || null,
      JSON.stringify(body),
      messageId,
      timestamp || new Date().toISOString(),
    ],
  );

  logger.info("Audit log entry written", {
    auditId,
    eventType: eventType || "subscription.created",
    entityType: "subscription",
    entityId: subscriptionId,
  });
}

module.exports.handler = withSqsConsumer("audit-log", processAuditLog);
