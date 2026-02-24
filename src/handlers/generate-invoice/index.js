/**
 * generate-invoice — SQS Consumer
 * ────────────────────────────────────────────────────────────────────────────
 * Triggered when a subscription is created.  Generates a draft invoice for
 * the first billing period.
 *
 * Flow:
 *   1. Receives "subscription.created" event from SQS (via SNS fan-out).
 *   2. Idempotency middleware checks processed_events table.
 *   3. Generates invoice number: INV-{YYYYMMDD}-{short-uuid}.
 *   4. Calculates line items from subscription amount and billing cycle.
 *   5. Inserts invoice with status "issued" and due date 30 days out.
 *   6. Reports success/failure back to SQS via batchItemFailures.
 *
 * Idempotency:
 *   The `withSqsConsumer` middleware prevents double-processing.  Even if
 *   SQS delivers the same message twice, only one invoice is created.
 *   The UNIQUE constraint on (tenant_id, invoice_number) is a final safety net.
 *
 * Failure handling:
 *   - Transient failures (DB timeout): Message stays in SQS, retried up to
 *     maxReceiveCount times with visibility-timeout backoff.
 *   - Permanent failures (invalid data): After max retries, message moves
 *     to the DLQ for manual investigation.
 */

const { v4: uuidv4 } = require("uuid");
const { queryWithTenant } = require("../../shared/db");
const { withSqsConsumer } = require("../../shared/sqs-consumer");
const { startTimer, recordBusinessMetric } = require("../../shared/metrics");

async function processSubscriptionCreated(body, { logger }) {
  const {
    tenantId,
    subscriptionId,
    planId,
    billingCycle,
    amount,
    currency,
    currentPeriodStart,
    currentPeriodEnd,
  } = body;

  const stopTimer = startTimer("invoice_generation", {
    TenantId: tenantId,
    PlanId: planId,
  });

  logger.info("Generating invoice for new subscription", {
    tenantId,
    subscriptionId,
    planId,
    amount,
  });

  // ── Generate invoice number ────────────────────────────────────────── //
  const now = new Date();
  const dateStr = now.toISOString().slice(0, 10).replace(/-/g, "");
  const shortId = uuidv4().slice(0, 8).toUpperCase();
  const invoiceNumber = `INV-${dateStr}-${shortId}`;

  // ── Build line items ───────────────────────────────────────────────── //
  const lineItems = [
    {
      description: `${planId} plan — ${billingCycle} subscription`,
      quantity: 1,
      unitPrice: amount,
      amount: amount,
      periodStart: currentPeriodStart,
      periodEnd: currentPeriodEnd,
    },
  ];

  // ── Calculate due date (30 days from creation) ─────────────────────── //
  const dueDate = new Date(now);
  dueDate.setDate(dueDate.getDate() + 30);

  // ── Insert invoice (tenant-scoped via RLS) ─────────────────────────── //
  const invoiceId = uuidv4();
  const result = await queryWithTenant(
    tenantId,
    `INSERT INTO invoices
       (id, tenant_id, subscription_id, invoice_number, status, amount,
        currency, line_items, due_date, created_at, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW(), NOW())
     RETURNING id, invoice_number, status, amount`,
    [
      invoiceId,
      tenantId,
      subscriptionId,
      invoiceNumber,
      "issued",
      amount,
      currency || "usd",
      JSON.stringify(lineItems),
      dueDate.toISOString(),
    ],
  );

  const invoice = result.rows[0];

  const durationMs = stopTimer();

  // Emit business metrics via EMF
  recordBusinessMetric("invoice_amount", amount, "Count", {
    TenantId: tenantId,
    PlanId: planId,
  });

  logger.info("Invoice generated successfully", {
    invoiceId: invoice.id,
    invoiceNumber: invoice.invoice_number,
    amount: invoice.amount,
    dueDate: dueDate.toISOString(),
    generationTimeMs: Math.round(durationMs),
  });
}

module.exports.handler = withSqsConsumer(
  "generate-invoice",
  processSubscriptionCreated,
);
