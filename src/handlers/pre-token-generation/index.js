/**
 * preTokenGenerationHandler
 * ────────────────────────────────────────────────────────────────────────────
 * Cognito Pre-Token-Generation Lambda Trigger (V1_0)
 *
 * Invoked by Cognito BEFORE issuing ID and access tokens.  Enriches the JWT
 * with custom claims that the API layer uses for authorization decisions:
 *
 *   • custom:plan_tier  — tenant's current subscription plan (free/starter/
 *     professional/enterprise).  API Gateway routes and Lambda handlers use
 *     this to enforce feature gates and rate limits.
 *
 *   • custom:features   — JSON-encoded feature flags derived from the plan.
 *     Enables progressive feature rollout without redeployment.
 *
 *   • custom:tenant_status — active/suspended/trial.  Suspended tenants get
 *     403 on write endpoints but can still read (graceful degradation).
 *
 * Design decisions:
 *
 *   • SINGLE DB QUERY: Fetch tenant + active subscription in one query using
 *     a LEFT JOIN.  This adds ~5-20ms to token generation (acceptable given
 *     tokens are issued infrequently — login + refresh every 60 min).
 *
 *   • GRACEFUL FALLBACK: If the DB query fails or returns no results, the
 *     handler returns DEFAULT claims (plan = "free", no features) instead of
 *     blocking authentication.  A user who can't get a fancy token is better
 *     than a user who can't log in at all.
 *
 *   • NO CACHING: Each token generation hits the DB.  At ~1 token per user
 *     per hour, the DB load is negligible.  Caching would introduce staleness
 *     issues when a tenant upgrades their plan.
 *
 *   • claimsToAddOrOverride: Cognito merges these into the issued token.
 *     The prefix "custom:" is NOT needed here — Cognito adds it automatically
 *     for custom claims.  Standard claims (email, sub) cannot be overridden.
 *
 *   • Event structure (V1_0):
 *       event.request.userAttributes["custom:tenant_id"]  → tenant UUID
 *       event.request.groupConfiguration.groupsToOverride  → Cognito groups
 *       event.response.claimsOverrideDetails → where we inject claims
 *
 * Cold start: ~200-400ms (Secrets Manager + DB connection).  Warm: ~10-20ms.
 * Since this runs on login/refresh only, cold starts are acceptable.
 */

const { getPool, querySystem } = require("../../shared/db");
const { createLogger } = require("../../shared/logger");

const logger = createLogger();

/**
 * Feature flags per plan tier.
 * These are injected into the JWT so the frontend and API can feature-gate
 * without additional API calls.
 */
const PLAN_FEATURES = {
  free: {
    maxUsers: 3,
    maxEventsPerMonth: 1000,
    invoiceExport: false,
    apiAccess: false,
    customBranding: false,
    prioritySupport: false,
    auditLog: false,
    webhooks: false,
  },
  starter: {
    maxUsers: 10,
    maxEventsPerMonth: 10000,
    invoiceExport: true,
    apiAccess: true,
    customBranding: false,
    prioritySupport: false,
    auditLog: false,
    webhooks: false,
  },
  professional: {
    maxUsers: 50,
    maxEventsPerMonth: 100000,
    invoiceExport: true,
    apiAccess: true,
    customBranding: true,
    prioritySupport: true,
    auditLog: true,
    webhooks: true,
  },
  enterprise: {
    maxUsers: -1, // Unlimited
    maxEventsPerMonth: -1,
    invoiceExport: true,
    apiAccess: true,
    customBranding: true,
    prioritySupport: true,
    auditLog: true,
    webhooks: true,
  },
};

const DEFAULT_PLAN = "free";

/**
 * Fetch tenant details and active subscription from the database.
 * Uses a LEFT JOIN so we always get the tenant row even if no subscription exists.
 */
async function getTenantDetails(tenantId) {
  const result = await querySystem(
    `SELECT
       t.id            AS tenant_id,
       t.plan          AS tenant_plan,
       t.status        AS tenant_status,
       t.settings      AS tenant_settings,
       s.plan_id       AS subscription_plan,
       s.status        AS subscription_status,
       s.billing_cycle AS subscription_billing_cycle
     FROM tenants t
     LEFT JOIN subscriptions s
       ON s.tenant_id = t.id
       AND s.status = 'active'
     WHERE t.id = $1
     ORDER BY s.created_at DESC
     LIMIT 1`,
    [tenantId],
  );

  return result.rows.length > 0 ? result.rows[0] : null;
}

/**
 * Determine the effective plan tier.
 * Priority: active subscription plan > tenant-level plan > default (free).
 */
function resolveEffectivePlan(tenantDetails) {
  if (!tenantDetails) return DEFAULT_PLAN;

  // Active subscription takes precedence over tenant-level plan
  if (
    tenantDetails.subscription_plan &&
    tenantDetails.subscription_status === "active"
  ) {
    return tenantDetails.subscription_plan;
  }

  return tenantDetails.tenant_plan || DEFAULT_PLAN;
}

/**
 * Build the feature flags object for the resolved plan.
 * Merges plan-level features with any tenant-specific overrides from settings.
 */
function resolveFeatures(plan, tenantDetails) {
  const baseFeatures = PLAN_FEATURES[plan] || PLAN_FEATURES[DEFAULT_PLAN];

  // Allow per-tenant feature overrides stored in tenants.settings
  if (tenantDetails?.tenant_settings) {
    const settings =
      typeof tenantDetails.tenant_settings === "string"
        ? JSON.parse(tenantDetails.tenant_settings)
        : tenantDetails.tenant_settings;

    if (settings.featureOverrides) {
      return { ...baseFeatures, ...settings.featureOverrides };
    }
  }

  return baseFeatures;
}

exports.handler = async (event, context) => {
  // Initialize logger with request context
  const requestLogger = logger.child({
    functionName: context.functionName,
    triggerSource: event.triggerSource,
    userName: event.userName,
    userPoolId: event.userPoolId,
  });

  requestLogger.info("Pre-token generation trigger invoked", {
    triggerSource: event.triggerSource,
    groups: event.request.groupConfiguration?.groupsToOverride,
  });

  // Extract tenant ID from Cognito custom attribute
  const tenantId = event.request.userAttributes["custom:tenant_id"];

  if (!tenantId) {
    requestLogger.warn("User has no tenant_id attribute — using defaults", {
      sub: event.request.userAttributes.sub,
    });

    event.response.claimsOverrideDetails = {
      claimsToAddOrOverride: {
        plan_tier: DEFAULT_PLAN,
        tenant_status: "unknown",
        features: JSON.stringify(PLAN_FEATURES[DEFAULT_PLAN]),
      },
    };

    return event;
  }

  try {
    // Ensure DB pool is initialized
    await getPool();

    const tenantDetails = await getTenantDetails(tenantId);

    if (!tenantDetails) {
      requestLogger.warn("Tenant not found in database — using defaults", {
        tenantId,
      });

      event.response.claimsOverrideDetails = {
        claimsToAddOrOverride: {
          plan_tier: DEFAULT_PLAN,
          tenant_status: "not_found",
          features: JSON.stringify(PLAN_FEATURES[DEFAULT_PLAN]),
        },
      };

      return event;
    }

    // Resolve effective plan and features
    const effectivePlan = resolveEffectivePlan(tenantDetails);
    const features = resolveFeatures(effectivePlan, tenantDetails);

    requestLogger.info("Enriching token with tenant claims", {
      tenantId,
      effectivePlan,
      tenantStatus: tenantDetails.tenant_status,
      hasActiveSubscription: !!tenantDetails.subscription_plan,
    });

    // Inject custom claims into the token
    event.response.claimsOverrideDetails = {
      claimsToAddOrOverride: {
        plan_tier: effectivePlan,
        tenant_status: tenantDetails.tenant_status || "active",
        features: JSON.stringify(features),
        billing_cycle: tenantDetails.subscription_billing_cycle || "none",
      },
    };

    return event;
  } catch (error) {
    // CRITICAL: Never block authentication due to enrichment failure.
    // Return default claims and log the error for investigation.
    requestLogger.error("Failed to fetch tenant details — using defaults", {
      tenantId,
      error,
    });

    event.response.claimsOverrideDetails = {
      claimsToAddOrOverride: {
        plan_tier: DEFAULT_PLAN,
        tenant_status: "error",
        features: JSON.stringify(PLAN_FEATURES[DEFAULT_PLAN]),
      },
    };

    return event;
  }
};
