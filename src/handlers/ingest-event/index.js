/**
 * ingestEventHandler
 * ────────────────────────────────────────────────────────────────────────────
 * POST /v1/events
 *
 * Ingests usage events for metered billing.  Events are stored in the
 * `billing_events` table and can be aggregated to calculate usage-based
 * charges during invoice generation.
 *
 * Event types:
 *   • api_call       — Track API request counts for metered billing
 *   • storage_used   — Track storage consumption in bytes
 *   • compute_time   — Track compute time in milliseconds
 *   • custom         — Tenant-defined event type for extension
 *
 * Idempotency:
 *   • The client can send an `idempotency_key` in the event payload.
 *   • The handler checks for duplicates before inserting.
 *   • This prevents double-counting if the client retries a failed request.
 *
 * Performance:
 *   • High-throughput endpoint (burst: 500 requests/sec in dev).
 *   • Minimal processing — validate and insert, return quickly.
 *   • In production, consider writing to SQS/Kinesis first and processing
 *     asynchronously for better throughput and reliability.
 */

const { v4: uuidv4 } = require('uuid');
const { withMiddleware, jsonResponse, AppError } = require('../../shared/middleware');
const { queryWithTenant } = require('../../shared/db');

const VALID_EVENT_TYPES = new Set([
  'api_call',
  'storage_used',
  'compute_time',
  'custom',
]);

async function ingestEventHandler(event, context, { tenant, body, logger, requestId }) {
  const { tenantId } = tenant;
  const {
    event_type,
    payload,
    idempotency_key,
    timestamp: eventTimestamp,
  } = body;

  logger.info('Ingesting billing event', { tenantId, eventType: event_type });

  // ── Validate event type ──────────────────────────────────────────────── //
  if (!VALID_EVENT_TYPES.has(event_type)) {
    throw new AppError(400, `Invalid event type: ${event_type}`, {
      validEventTypes: [...VALID_EVENT_TYPES],
    });
  }

  // ── Validate payload has quantity ────────────────────────────────────── //
  if (payload.quantity !== undefined && (typeof payload.quantity !== 'number' || payload.quantity < 0)) {
    throw new AppError(400, 'payload.quantity must be a non-negative number');
  }

  // ── Idempotency check ───────────────────────────────────────────────── //
  if (idempotency_key) {
    const duplicate = await queryWithTenant(
      tenantId,
      `SELECT id FROM billing_events
       WHERE tenant_id = $1 AND idempotency_key = $2
       LIMIT 1`,
      [tenantId, idempotency_key]
    );

    if (duplicate.rows.length > 0) {
      logger.info('Duplicate event detected — returning existing', {
        idempotencyKey: idempotency_key,
        existingEventId: duplicate.rows[0].id,
      });

      return jsonResponse(200, {
        message: 'Event already processed (idempotent)',
        eventId: duplicate.rows[0].id,
        duplicate: true,
        requestId,
      });
    }
  }

  // ── Insert the event ─────────────────────────────────────────────────── //
  const eventId = uuidv4();
  const now = new Date().toISOString();

  const result = await queryWithTenant(
    tenantId,
    `INSERT INTO billing_events
       (id, tenant_id, event_type, payload, quantity, idempotency_key,
        event_timestamp, created_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
     RETURNING id, event_type, quantity, event_timestamp, created_at`,
    [
      eventId,
      tenantId,
      event_type,
      JSON.stringify(payload),
      payload.quantity || 1,
      idempotency_key || null,
      eventTimestamp ? new Date(eventTimestamp).toISOString() : now,
      now,
    ]
  );

  const created = result.rows[0];

  logger.info('Billing event ingested', {
    eventId,
    eventType: event_type,
    quantity: created.quantity,
  });

  return jsonResponse(201, {
    message: 'Event ingested successfully',
    event: {
      id: created.id,
      eventType: created.event_type,
      quantity: parseFloat(created.quantity),
      eventTimestamp: created.event_timestamp,
      createdAt: created.created_at,
    },
    requestId,
  });
}

module.exports.handler = withMiddleware(ingestEventHandler, {
  schemaName: 'ingest-event',
  requireBody: true,
});
