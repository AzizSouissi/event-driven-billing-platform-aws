/**
 * JSON Schema Validation — SSM-backed with in-memory caching
 * ────────────────────────────────────────────────────────────────────────────
 * Loads schemas from SSM Parameter Store on first access (per schema name),
 * then caches the compiled validator for the lifetime of the Lambda container.
 *
 * This decouples schema definitions (managed in Terraform) from Lambda code
 * (deployed via CI/CD) — you can update schemas without redeploying functions.
 */

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const Ajv = require('ajv');
const addFormats = require('ajv-formats');
const { createLogger } = require('./logger');

const logger = createLogger();
const ssm = new SSMClient({ region: process.env.AWS_REGION || 'us-east-1' });

const ajv = new Ajv({ allErrors: true, coerceTypes: false });
addFormats(ajv);

const PROJECT = process.env.PROJECT || 'billing-platform';
const ENVIRONMENT = process.env.ENVIRONMENT || 'dev';

// Cache: schemaName → compiled ajv validate function
const _schemaCache = new Map();

/**
 * Get a compiled JSON Schema validator.
 * First call fetches from SSM and compiles; subsequent calls return cache.
 *
 * @param {string} schemaName - e.g., "create-tenant"
 * @returns {import('ajv').ValidateFunction | null}
 */
async function getSchemaValidator(schemaName) {
  if (_schemaCache.has(schemaName)) {
    return _schemaCache.get(schemaName);
  }

  try {
    const paramName = `/${PROJECT}/${ENVIRONMENT}/api/schemas/${schemaName}`;
    logger.debug('Loading schema from SSM', { paramName });

    const response = await ssm.send(new GetParameterCommand({ Name: paramName }));
    const schema = JSON.parse(response.Parameter.Value);
    const validate = ajv.compile(schema);

    _schemaCache.set(schemaName, validate);
    logger.info('Schema loaded and compiled', { schemaName });

    return validate;
  } catch (err) {
    // If schema doesn't exist, log a warning and skip validation
    if (err.name === 'ParameterNotFound') {
      logger.warn('Schema not found in SSM — skipping validation', { schemaName });
      _schemaCache.set(schemaName, null);
      return null;
    }
    throw err;
  }
}

module.exports = { getSchemaValidator };
