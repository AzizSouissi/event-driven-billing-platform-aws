/**
 * Lambda Middleware — Extracts tenant context, validates requests, handles errors
 * ────────────────────────────────────────────────────────────────────────────
 * Design decisions:
 *
 *   • WRAPPER PATTERN: Each handler is wrapped with `withMiddleware(handler)`.
 *     The middleware runs BEFORE the handler and standardizes:
 *       a) JWT claim extraction (tenant_id, groups, sub)
 *       b) Request body parsing + JSON Schema validation
 *       c) Structured error responses with correlation IDs
 *       d) Uncaught exception handling with proper logging
 *
 *   • TENANT EXTRACTION: The `custom:tenant_id` claim is extracted from the
 *     JWT authorizer context injected by API Gateway.  If missing, the request
 *     is rejected with 403 — this should never happen in normal flow because
 *     Cognito always includes it, but defense-in-depth matters.
 *
 *   • SCHEMA VALIDATION: Uses `ajv` with JSON Schema draft-07.  Schemas are
 *     loaded from SSM parameters on cold start and cached.  Invalid bodies
 *     return 400 with field-level error details.
 *
 *   • ERROR HANDLING: All errors are caught, logged, and returned as JSON.
 *     Known errors (AppError) return their HTTP status.  Unknown errors
 *     return 500 with the request ID for correlation — no stack traces
 *     are ever sent to the client.
 */

const { createLogger } = require('./logger');
const { getSchemaValidator } = require('./validation');

/**
 * Application error with HTTP status code.
 * Throw this from handlers for controlled error responses.
 */
class AppError extends Error {
  constructor(statusCode, message, details = null) {
    super(message);
    this.name = 'AppError';
    this.statusCode = statusCode;
    this.details = details;
  }
}

/**
 * Extract tenant context from API Gateway JWT authorizer claims.
 */
function extractTenantContext(event) {
  const claims = event.requestContext?.authorizer?.jwt?.claims;

  if (!claims) {
    throw new AppError(401, 'Missing authorization claims');
  }

  const tenantId = claims['custom:tenant_id'];
  if (!tenantId) {
    throw new AppError(403, 'Missing tenant_id claim — user not assigned to a tenant');
  }

  // Parse groups — Cognito sends as a string "[ADMIN, USER]" or a JSON array
  let groups = claims['cognito:groups'] || [];
  if (typeof groups === 'string') {
    groups = groups.replace(/[\[\]]/g, '').split(',').map(g => g.trim()).filter(Boolean);
  }

  return {
    tenantId,
    userId: claims.sub,
    email: claims.email,
    groups,
    isAdmin: groups.includes('ADMIN'),
  };
}

/**
 * Parse and validate request body against a JSON Schema.
 * Returns the parsed body or throws AppError(400).
 */
async function parseAndValidateBody(event, schemaName) {
  if (!event.body) {
    throw new AppError(400, 'Request body is required');
  }

  let body;
  try {
    body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
  } catch {
    throw new AppError(400, 'Invalid JSON in request body');
  }

  if (schemaName) {
    const validate = await getSchemaValidator(schemaName);
    if (validate && !validate(body)) {
      throw new AppError(400, 'Request validation failed', {
        errors: validate.errors.map(e => ({
          field: e.instancePath || '/',
          message: e.message,
          params: e.params,
        })),
      });
    }
  }

  return body;
}

/**
 * Build a standardized JSON response.
 */
function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'X-Content-Type-Options': 'nosniff',
      'Cache-Control': 'no-store',
    },
    body: JSON.stringify(body),
  };
}

/**
 * Middleware wrapper for Lambda handlers.
 *
 * Usage:
 *   module.exports.handler = withMiddleware(async (event, context, { tenant, logger }) => {
 *     // tenant.tenantId, tenant.isAdmin, etc. are available
 *     return jsonResponse(200, { data: ... });
 *   });
 *
 * Options:
 *   - requireAdmin: boolean — reject non-ADMIN users with 403
 *   - schemaName: string — SSM schema key for body validation
 *   - requireBody: boolean — reject if body is missing (default: true for POST/PUT)
 */
function withMiddleware(handler, options = {}) {
  return async (event, context) => {
    const logger = createLogger(context);
    const requestId = event.requestContext?.requestId || context.awsRequestId;

    logger.withContext({ requestId });

    try {
      // ── Extract tenant context ──────────────────────────────────────── //
      const tenant = extractTenantContext(event);
      logger.withContext({ tenantId: tenant.tenantId, userId: tenant.userId });

      logger.info('Request received', {
        method: event.requestContext?.http?.method,
        path: event.requestContext?.http?.path,
        routeKey: event.routeKey,
      });

      // ── Admin check ─────────────────────────────────────────────────── //
      if (options.requireAdmin && !tenant.isAdmin) {
        throw new AppError(403, 'This operation requires ADMIN role');
      }

      // ── Body parsing + validation ───────────────────────────────────── //
      let body = null;
      const method = event.requestContext?.http?.method;
      const needsBody = options.requireBody ?? ['POST', 'PUT', 'PATCH'].includes(method);

      if (needsBody) {
        body = await parseAndValidateBody(event, options.schemaName);
      }

      // ── Query parameters ────────────────────────────────────────────── //
      const queryParams = event.queryStringParameters || {};

      // ── Execute handler ─────────────────────────────────────────────── //
      const result = await handler(event, context, {
        tenant,
        body,
        queryParams,
        logger,
        requestId,
      });

      logger.info('Request completed', {
        statusCode: result.statusCode,
      });

      return result;

    } catch (err) {
      // ── Error handling ──────────────────────────────────────────────── //
      if (err instanceof AppError) {
        logger.warn('Application error', {
          statusCode: err.statusCode,
          message: err.message,
          details: err.details,
        });

        return jsonResponse(err.statusCode, {
          error: err.message,
          details: err.details,
          requestId,
        });
      }

      // Unknown / unexpected error — do NOT expose details to the client
      logger.error('Unhandled error', { error: err });

      return jsonResponse(500, {
        error: 'Internal server error',
        requestId,
      });
    }
  };
}

module.exports = {
  AppError,
  withMiddleware,
  jsonResponse,
  extractTenantContext,
  parseAndValidateBody,
};
