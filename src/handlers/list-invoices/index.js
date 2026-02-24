/**
 * generateInvoiceHandler (list-invoices)
 * ────────────────────────────────────────────────────────────────────────────
 * GET /v1/invoices
 *
 * Lists invoices for the calling tenant.  Supports pagination, date filtering,
 * and status filtering.  Invoice generation is triggered by the billing engine
 * (cron/event) — this handler only reads.
 *
 * Tenant isolation:
 *   • `queryWithTenant()` sets `app.tenant_id` before every query.
 *   • RLS policy: `USING (tenant_id = current_setting('app.tenant_id')::uuid)`
 *   • The handler also adds `tenant_id = $1` in the WHERE clause (belt +
 *     suspenders — defense in depth).
 *
 * Pagination:
 *   • Cursor-based using `created_at` + `id` (no OFFSET — stays fast for
 *     large result sets).
 *   • Response includes `nextCursor` for the client to pass as `?cursor=`.
 *
 * Query parameters:
 *   • status:  filter by invoice status (draft, issued, paid, overdue, void)
 *   • from:    start date (ISO 8601)
 *   • to:      end date (ISO 8601)
 *   • limit:   page size (default: 20, max: 100)
 *   • cursor:  opaque cursor for pagination
 */

const { withMiddleware, jsonResponse, AppError } = require('../../shared/middleware');
const { queryWithTenant } = require('../../shared/db');

const VALID_STATUSES = new Set(['draft', 'issued', 'paid', 'overdue', 'void']);
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 100;

/**
 * Decode an opaque Base64 cursor into { createdAt, id }.
 */
function decodeCursor(cursor) {
  try {
    const decoded = Buffer.from(cursor, 'base64url').toString('utf-8');
    const parsed = JSON.parse(decoded);
    if (!parsed.createdAt || !parsed.id) throw new Error('Invalid cursor');
    return parsed;
  } catch {
    throw new AppError(400, 'Invalid pagination cursor');
  }
}

/**
 * Encode { createdAt, id } into an opaque Base64 cursor.
 */
function encodeCursor(row) {
  return Buffer.from(JSON.stringify({
    createdAt: row.created_at,
    id: row.id,
  })).toString('base64url');
}

async function generateInvoiceHandler(event, context, { tenant, queryParams, logger, requestId }) {
  const { tenantId } = tenant;

  // ── Parse query parameters ──────────────────────────────────────────── //
  let limit = parseInt(queryParams.limit, 10) || DEFAULT_LIMIT;
  limit = Math.min(Math.max(limit, 1), MAX_LIMIT);

  const status = queryParams.status;
  const from = queryParams.from;
  const to = queryParams.to;
  const cursor = queryParams.cursor;

  // Validate status filter
  if (status && !VALID_STATUSES.has(status)) {
    throw new AppError(400, `Invalid status filter: ${status}`, {
      validStatuses: [...VALID_STATUSES],
    });
  }

  // Validate date filters
  if (from && isNaN(Date.parse(from))) {
    throw new AppError(400, 'Invalid "from" date — use ISO 8601 format');
  }
  if (to && isNaN(Date.parse(to))) {
    throw new AppError(400, 'Invalid "to" date — use ISO 8601 format');
  }

  logger.info('Listing invoices', { tenantId, status, from, to, limit, hasCursor: !!cursor });

  // ── Build query dynamically ─────────────────────────────────────────── //
  const conditions = ['tenant_id = $1'];
  const params = [tenantId];
  let paramIndex = 2;

  if (status) {
    conditions.push(`status = $${paramIndex++}`);
    params.push(status);
  }

  if (from) {
    conditions.push(`created_at >= $${paramIndex++}`);
    params.push(new Date(from).toISOString());
  }

  if (to) {
    conditions.push(`created_at <= $${paramIndex++}`);
    params.push(new Date(to).toISOString());
  }

  if (cursor) {
    const decoded = decodeCursor(cursor);
    conditions.push(`(created_at, id) < ($${paramIndex}, $${paramIndex + 1})`);
    params.push(decoded.createdAt, decoded.id);
    paramIndex += 2;
  }

  const whereClause = conditions.join(' AND ');

  // Fetch one extra row to determine if there are more pages
  const query = `
    SELECT id, tenant_id, subscription_id, invoice_number, status,
           amount, currency, line_items, due_date, paid_at, created_at, updated_at
    FROM invoices
    WHERE ${whereClause}
    ORDER BY created_at DESC, id DESC
    LIMIT $${paramIndex}
  `;
  params.push(limit + 1);

  const result = await queryWithTenant(tenantId, query, params);

  // ── Determine pagination ────────────────────────────────────────────── //
  const hasMore = result.rows.length > limit;
  const rows = hasMore ? result.rows.slice(0, limit) : result.rows;
  const nextCursor = hasMore ? encodeCursor(rows[rows.length - 1]) : null;

  // ── Format response ─────────────────────────────────────────────────── //
  const invoices = rows.map(row => ({
    id: row.id,
    subscriptionId: row.subscription_id,
    invoiceNumber: row.invoice_number,
    status: row.status,
    amount: parseFloat(row.amount),
    currency: row.currency,
    lineItems: typeof row.line_items === 'string'
      ? JSON.parse(row.line_items)
      : row.line_items || [],
    dueDate: row.due_date,
    paidAt: row.paid_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }));

  logger.info('Invoices retrieved', {
    count: invoices.length,
    hasMore,
  });

  return jsonResponse(200, {
    invoices,
    pagination: {
      limit,
      count: invoices.length,
      hasMore,
      ...(nextCursor && { nextCursor }),
    },
    requestId,
  });
}

module.exports.handler = withMiddleware(generateInvoiceHandler, {
  requireBody: false,
});
