/**
 * createSubscriptionHandler
 * ────────────────────────────────────────────────────────────────────────────
 * POST /v1/subscriptions
 *
 * Creates a new subscription for the calling tenant.  The tenant_id is pulled
 * from the JWT — users cannot create subscriptions for other tenants.
 *
 * Flow:
 *   1. Middleware extracts tenant context from JWT, validates body.
 *   2. Handler validates the plan exists and is active.
 *   3. Checks for existing active subscription (one active sub per tenant).
 *   4. Inserts into `subscriptions` table with tenant-scoped query.
 *   5. Returns created subscription with status 201.
 *
 * Tenant isolation:
 *   • All queries use `queryWithTenant()` which sets `app.tenant_id` before
 *     every query.  PostgreSQL RLS policies filter results automatically.
 *   • Even if the handler code had a bug, the DB would prevent cross-tenant
 *     access.
 *
 * Billing cycle:
 *   • Supported values: monthly, quarterly, annual.
 *   • `current_period_start` and `current_period_end` are calculated based
 *     on the cycle at creation time.
 */

const { v4: uuidv4 } = require('uuid');
const { withMiddleware, jsonResponse, AppError } = require('../../shared/middleware');
const { queryWithTenant, transactionWithTenant } = require('../../shared/db');

// ── Billing cycle helpers ──────────────────────────────────────────────── //

const BILLING_CYCLES = {
  monthly:   { months: 1 },
  quarterly: { months: 3 },
  annual:    { months: 12 },
};

function calculatePeriodEnd(startDate, cycle) {
  const config = BILLING_CYCLES[cycle];
  if (!config) {
    throw new AppError(400, `Invalid billing cycle: ${cycle}`, {
      validCycles: Object.keys(BILLING_CYCLES),
    });
  }

  const end = new Date(startDate);
  end.setMonth(end.getMonth() + config.months);
  return end;
}

// ── Plan catalog (in production, this would come from a DB table) ──────── //

const PLANS = {
  free:       { name: 'Free',       priceMonthly: 0,     maxEvents: 1000 },
  starter:    { name: 'Starter',    priceMonthly: 29,    maxEvents: 10000 },
  pro:        { name: 'Professional', priceMonthly: 99,  maxEvents: 100000 },
  enterprise: { name: 'Enterprise', priceMonthly: 499,   maxEvents: -1 },  // unlimited
};

// ── Handler ────────────────────────────────────────────────────────────── //

async function createSubscriptionHandler(event, context, { tenant, body, logger, requestId }) {
  const { tenantId } = tenant;
  const { plan_id, billing_cycle, metadata } = body;

  logger.info('Creating subscription', { tenantId, planId: plan_id, billingCycle: billing_cycle });

  // ── Validate plan ────────────────────────────────────────────────────── //
  const plan = PLANS[plan_id];
  if (!plan) {
    throw new AppError(400, `Unknown plan: ${plan_id}`, {
      validPlans: Object.keys(PLANS),
    });
  }

  // ── Check for existing active subscription ───────────────────────────── //
  const existingSub = await queryWithTenant(
    tenantId,
    `SELECT id, plan_id, status FROM subscriptions
     WHERE tenant_id = $1 AND status IN ('active', 'trialing')
     LIMIT 1`,
    [tenantId]
  );

  if (existingSub.rows.length > 0) {
    const sub = existingSub.rows[0];
    throw new AppError(409, 'Tenant already has an active subscription', {
      existingSubscriptionId: sub.id,
      currentPlan: sub.plan_id,
      currentStatus: sub.status,
    });
  }

  // ── Calculate billing period ─────────────────────────────────────────── //
  const now = new Date();
  const periodStart = now;
  const periodEnd = calculatePeriodEnd(now, billing_cycle);

  // ── Calculate pricing ─────────────────────────────────────────────────── //
  let amount;
  switch (billing_cycle) {
    case 'monthly':   amount = plan.priceMonthly; break;
    case 'quarterly': amount = plan.priceMonthly * 3 * 0.9; break;   // 10% discount
    case 'annual':    amount = plan.priceMonthly * 12 * 0.8; break;  // 20% discount
    default:          amount = plan.priceMonthly;
  }

  // ── Insert subscription within a transaction ─────────────────────────── //
  const subscriptionId = uuidv4();
  const nowIso = now.toISOString();

  const [insertResult] = await transactionWithTenant(tenantId, [
    {
      text: `INSERT INTO subscriptions
               (id, tenant_id, plan_id, status, billing_cycle, amount, currency,
                current_period_start, current_period_end, metadata, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
             RETURNING *`,
      params: [
        subscriptionId,
        tenantId,
        plan_id,
        'active',
        billing_cycle,
        amount,
        'usd',
        periodStart.toISOString(),
        periodEnd.toISOString(),
        JSON.stringify(metadata || {}),
        nowIso,
        nowIso,
      ],
    },
  ]);

  const subscription = insertResult.rows[0];

  logger.info('Subscription created successfully', {
    subscriptionId,
    planId: plan_id,
    billingCycle: billing_cycle,
    amount,
    periodEnd: periodEnd.toISOString(),
  });

  return jsonResponse(201, {
    message: 'Subscription created successfully',
    subscription: {
      id: subscription.id,
      tenantId: subscription.tenant_id,
      planId: subscription.plan_id,
      status: subscription.status,
      billingCycle: subscription.billing_cycle,
      amount: parseFloat(subscription.amount),
      currency: subscription.currency,
      currentPeriodStart: subscription.current_period_start,
      currentPeriodEnd: subscription.current_period_end,
      metadata: typeof subscription.metadata === 'string'
        ? JSON.parse(subscription.metadata)
        : subscription.metadata,
      createdAt: subscription.created_at,
    },
    requestId,
  });
}

module.exports.handler = withMiddleware(createSubscriptionHandler, {
  schemaName: 'create-subscription',
  requireBody: true,
});
