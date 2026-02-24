-- ============================================================================
-- 002_event_processing.sql
-- ============================================================================
-- Adds tables required by the event-driven architecture:
--   1. processed_events — Idempotency guard for SQS consumers
--   2. audit_logs       — Append-only audit trail for billing events
--
-- These tables support the SNS → SQS → Lambda fan-out pattern where
-- at-least-once delivery requires deduplication.
-- ============================================================================
-- ============================================================================
-- PROCESSED EVENTS (Idempotency)
-- ============================================================================
-- Each SQS consumer checks this table before processing a message.
-- The UNIQUE constraint on idempotency_key prevents duplicate processing.
--
-- Key format: "{consumer}:{subscriptionId}:{messageId}"
--   e.g., "generate-invoice:sub-uuid:sqs-msg-id"
--
-- Lifecycle:
--   1. Consumer inserts with status = 'processing'
--   2. On success, updates to status = 'completed'
--   3. On failure, deletes the row (allows retry)
--   4. Rows older than 7 days should be cleaned up by a scheduled job
CREATE TABLE IF NOT EXISTS processed_events (
    id BIGSERIAL PRIMARY KEY,
    idempotency_key VARCHAR(512) NOT NULL,
    consumer VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'processing',
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    CONSTRAINT processed_events_key_unique UNIQUE (idempotency_key),
    CONSTRAINT processed_events_status_check CHECK (
        status IN ('processing', 'completed', 'failed')
    )
);

CREATE INDEX idx_processed_events_consumer ON processed_events (consumer);

CREATE INDEX idx_processed_events_status ON processed_events (status);

CREATE INDEX idx_processed_events_processed_at ON processed_events (processed_at);

-- ============================================================================
-- AUDIT LOGS
-- ============================================================================
-- Append-only audit trail.  Every significant system event is recorded here
-- with the full payload snapshot at the time of the event.
--
-- No RLS — admin users need cross-tenant reporting capability.
-- Access control is enforced at the application layer.
--
-- No UPDATE/DELETE triggers — this table is designed to be immutable.
-- In production, consider using a DO INSTEAD NOTHING rule or revoking
-- UPDATE/DELETE from the application role.
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    event_type VARCHAR(100) NOT NULL,
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID,
    actor_id UUID,
    payload JSONB NOT NULL DEFAULT '{}',
    source_message_id VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_logs_tenant_id ON audit_logs (tenant_id);

CREATE INDEX idx_audit_logs_event_type ON audit_logs (event_type);

CREATE INDEX idx_audit_logs_entity ON audit_logs (entity_type, entity_id);

CREATE INDEX idx_audit_logs_created_at ON audit_logs (created_at DESC);

CREATE INDEX idx_audit_logs_tenant_time ON audit_logs (tenant_id, created_at DESC);