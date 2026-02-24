/**
 * Database Connection Pool — Singleton with Secrets Manager Integration
 * ────────────────────────────────────────────────────────────────────────────
 * Design decisions:
 *
 *   • SINGLETON POOL: The `pg.Pool` is created ONCE per Lambda execution
 *     environment (container) and reused across warm invocations.  This is
 *     the #1 cold-start optimization — creating a pool costs ~50-100ms,
 *     but only happens on the first invocation.
 *
 *   • MODULE-LEVEL VARIABLE: The pool is stored in `_pool` at module scope.
 *     Lambda containers freeze/thaw the Node.js process, so module-level
 *     state persists between invocations of the SAME container.
 *
 *   • CONNECTION LIMITS: max = 2 per Lambda instance.  Lambda can scale to
 *     hundreds of concurrent containers, each with its own pool.  If max = 10
 *     and 100 containers exist, that's 1,000 connections — more than most
 *     RDS instances support.  Keep this LOW and rely on RDS Proxy for
 *     connection multiplexing in prod.
 *
 *   • IDLE TIMEOUT: 60s.  Lambda containers are frozen after ~5-15 min of
 *     inactivity.  Idle connections tie up RDS slots.  Short idle timeout
 *     releases them quickly.
 *
 *   • SECRETS MANAGER: Credentials are fetched once per cold start and
 *     cached in `_cachedSecret`.  The secret is a JSON object:
 *       { "host": "...", "port": 5432, "dbname": "...", "username": "...", "password": "..." }
 *     Using Secrets Manager (not env vars) ensures:
 *       a) Credentials are encrypted at rest (KMS)
 *       b) Automatic rotation is possible
 *       c) No plaintext in Terraform state or Lambda console
 *
 *   • SSL: Required (rejectUnauthorized: false for RDS CA — in prod, pin
 *     the RDS CA bundle for full verification).
 *
 *   • STATEMENT TIMEOUT: 8s per query.  Lambda timeout is 10s, so this
 *     ensures queries abort before the function times out, giving us time
 *     to return a proper error response instead of a timeout.
 */

const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");
const { Pool } = require("pg");
const { createLogger } = require("./logger");

const logger = createLogger();

// Module-level singletons — persist across warm invocations
let _pool = null;
let _cachedSecret = null;

const SECRET_ARN = process.env.DB_SECRET_ARN;
const AWS_REGION = process.env.AWS_REGION || "us-east-1";

/**
 * Fetch DB credentials from Secrets Manager (cached after first call).
 */
async function getDbCredentials() {
  if (_cachedSecret) return _cachedSecret;

  const client = new SecretsManagerClient({ region: AWS_REGION });
  const command = new GetSecretValueCommand({ SecretId: SECRET_ARN });

  logger.info("Fetching DB credentials from Secrets Manager", {
    secretArn: SECRET_ARN,
  });
  const response = await client.send(command);
  _cachedSecret = JSON.parse(response.SecretString);

  logger.info("DB credentials retrieved successfully", {
    host: _cachedSecret.host,
    dbname: _cachedSecret.dbname,
    username: _cachedSecret.username,
    // Never log the password
  });

  return _cachedSecret;
}

/**
 * Get or create the connection pool.
 * Called at the start of every handler invocation.
 */
async function getPool() {
  if (_pool) return _pool;

  const creds = await getDbCredentials();

  _pool = new Pool({
    host: creds.host,
    port: creds.port || 5432,
    database: creds.dbname,
    user: creds.username,
    password: creds.password,

    // ── Connection limits ──────────────────────────────────────────────── //
    max: 2, // Low — many Lambda containers share one RDS
    min: 0, // Don't pre-create connections
    idleTimeoutMillis: 60000, // Release idle connections after 60s
    connectionTimeoutMillis: 5000, // Fail fast if RDS is unreachable

    // ── Query safety ───────────────────────────────────────────────────── //
    statement_timeout: 8000, // Kill queries after 8s (Lambda timeout is 10s)

    // ── SSL ────────────────────────────────────────────────────────────── //
    ssl: {
      rejectUnauthorized: false, // RDS uses Amazon-issued CA; pin in prod
    },
  });

  // Log pool events for observability
  _pool.on("connect", () => logger.debug("New DB connection established"));
  _pool.on("error", (err) =>
    logger.error("Unexpected pool error", { error: err }),
  );

  logger.info("Connection pool created", {
    host: creds.host,
    database: creds.dbname,
    maxConnections: 2,
  });

  return _pool;
}

/**
 * Execute a query with automatic tenant scoping.
 *
 * CRITICAL: This is the primary defense against cross-tenant data leakage.
 * Every query goes through this function, which:
 *   1. Sets the session variable `app.tenant_id` via SET LOCAL
 *   2. Executes the query within a transaction
 *   3. The RLS (Row-Level Security) policy on the DB uses `app.tenant_id`
 *      to filter rows automatically
 *
 * Even if application code forgets a WHERE clause, RLS prevents leakage.
 */
async function queryWithTenant(tenantId, text, params = []) {
  const pool = await getPool();
  const client = await pool.connect();

  try {
    await client.query("BEGIN");

    // Set tenant context for RLS policies — LOCAL scopes to this transaction
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [
      tenantId,
    ]);

    const result = await client.query(text, params);

    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

/**
 * Execute a query WITHOUT tenant scoping (for admin/system operations like
 * creating a new tenant where the tenant doesn't exist yet).
 */
async function querySystem(text, params = []) {
  const pool = await getPool();
  return pool.query(text, params);
}

/**
 * Execute multiple queries in a single transaction with tenant scoping.
 */
async function transactionWithTenant(tenantId, queries) {
  const pool = await getPool();
  const client = await pool.connect();

  try {
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [
      tenantId,
    ]);

    const results = [];
    for (const { text, params } of queries) {
      results.push(await client.query(text, params || []));
    }

    await client.query("COMMIT");
    return results;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

/**
 * Graceful shutdown — drain the pool.
 * Called if we ever need to clean up (e.g., in tests).
 */
async function closePool() {
  if (_pool) {
    await _pool.end();
    _pool = null;
    _cachedSecret = null;
    logger.info("Connection pool closed");
  }
}

module.exports = {
  getPool,
  queryWithTenant,
  querySystem,
  transactionWithTenant,
  closePool,
};
