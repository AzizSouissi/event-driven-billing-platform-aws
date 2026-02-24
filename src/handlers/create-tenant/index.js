/**
 * createTenantHandler
 * ────────────────────────────────────────────────────────────────────────────
 * POST /v1/tenants
 *
 * Creates a new tenant in the billing platform.  Only users with the ADMIN
 * group can create tenants.
 *
 * Flow:
 *   1. Middleware extracts JWT claims and validates the request body.
 *   2. Handler checks the caller has ADMIN role.
 *   3. Generates a new tenant UUID.
 *   4. Inserts into `tenants` table (system query — no RLS, because the
 *      tenant doesn't exist yet).
 *   5. Returns the created tenant with status 201.
 *
 * Cold start considerations:
 *   • First invocation incurs ~200-400ms for Secrets Manager + DB connection.
 *   • Subsequent warm invocations reuse the pool (~5ms overhead).
 *   • The SSM schema fetch adds ~50ms on cold start (then cached).
 *   • Provisioned Concurrency can eliminate cold starts for critical paths.
 */

const { v4: uuidv4 } = require('uuid');
const { withMiddleware, jsonResponse, AppError } = require('../../shared/middleware');
const { querySystem } = require('../../shared/db');

async function createTenantHandler(event, context, { tenant, body, logger, requestId }) {
  logger.info('Creating new tenant', { tenantName: body.name });

  // ── Authorization: only ADMIN users can create tenants ───────────────── //
  if (!tenant.isAdmin) {
    throw new AppError(403, 'Only administrators can create tenants');
  }

  // ── Check for duplicate tenant name ──────────────────────────────────── //
  const existing = await querySystem(
    'SELECT id FROM tenants WHERE LOWER(name) = LOWER($1) AND status != $2',
    [body.name, 'deleted']
  );

  if (existing.rows.length > 0) {
    throw new AppError(409, 'A tenant with this name already exists', {
      existingTenantId: existing.rows[0].id,
    });
  }

  // ── Create the tenant ────────────────────────────────────────────────── //
  const tenantId = uuidv4();
  const now = new Date().toISOString();

  const result = await querySystem(
    `INSERT INTO tenants (id, name, email, plan, status, settings, created_by, created_at, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
     RETURNING id, name, email, plan, status, settings, created_at`,
    [
      tenantId,
      body.name,
      body.email,
      body.plan || 'free',
      'active',
      JSON.stringify(body.settings || {}),
      tenant.userId,
      now,
      now,
    ]
  );

  const created = result.rows[0];

  logger.info('Tenant created successfully', {
    newTenantId: tenantId,
    plan: created.plan,
  });

  return jsonResponse(201, {
    message: 'Tenant created successfully',
    tenant: {
      id: created.id,
      name: created.name,
      email: created.email,
      plan: created.plan,
      status: created.status,
      settings: typeof created.settings === 'string'
        ? JSON.parse(created.settings)
        : created.settings,
      createdAt: created.created_at,
    },
    requestId,
  });
}

// Wrap with middleware — schema validation uses SSM schema "create-tenant"
module.exports.handler = withMiddleware(createTenantHandler, {
  schemaName: 'create-tenant',
  requireBody: true,
});
