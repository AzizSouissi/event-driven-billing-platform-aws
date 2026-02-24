-- ============================================================================
-- 001_initial_schema.sql
-- ============================================================================
-- Multi-tenant billing platform database schema with Row-Level Security (RLS).
--
-- SECURITY MODEL:
--   Every table with tenant data has:
--     1. A `tenant_id` column (NOT NULL, indexed)
--     2. An RLS policy that filters rows by `app.tenant_id` session variable
--     3. A composite index on (tenant_id, ...) for efficient filtered queries
--
--   The application sets `app.tenant_id` via:
--     SELECT set_config('app.tenant_id', '<uuid>', true);
--   BEFORE every query (see src/shared/db.js — queryWithTenant).
--
--   Even if application code omits a WHERE clause, the DB enforces isolation.
--
-- CONVENTIONS:
--   • All tables use UUID primary keys (no sequential IDs — prevents
--     enumeration attacks)
--   • Timestamps are TIMESTAMPTZ (timezone-aware, stored as UTC)
--   • Money is NUMERIC(12,2) — never use FLOAT for currency
--   • JSON columns use JSONB (binary, indexable)
--   • Soft deletes via `status = 'deleted'` — no actual row removal
-- ============================================================================
-- ── Extensions ────────────────────────────────────────────────────────── --
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- TENANTS
-- ============================================================================
-- The root entity.  Every other table references this via tenant_id.
-- Tenant creation uses `querySystem()` (bypasses RLS) because the
-- tenant doesn't exist yet when being created.
-- ============================================================================
CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    plan VARCHAR(50) NOT NULL DEFAULT 'free',
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    settings JSONB NOT NULL DEFAULT '{}',
    created_by UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT tenants_name_unique UNIQUE (name),
    CONSTRAINT tenants_email_check CHECK (
        email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}$'
    ),
    CONSTRAINT tenants_status_check CHECK (status IN ('active', 'suspended', 'deleted'))
);

CREATE INDEX idx_tenants_email ON tenants (email);

CREATE INDEX idx_tenants_status ON tenants (status);

-- No RLS on tenants — the application uses `querySystem()` for tenant
-- operations.  Only ADMIN users can create/manage tenants, enforced at
-- the application layer.
-- ============================================================================
-- SUBSCRIPTIONS
-- ============================================================================
CREATE TABLE IF NOT EXISTS subscriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    plan_id VARCHAR(50) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    billing_cycle VARCHAR(20) NOT NULL DEFAULT 'monthly',
    amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    currency VARCHAR(3) NOT NULL DEFAULT 'usd',
    current_period_start TIMESTAMPTZ NOT NULL,
    current_period_end TIMESTAMPTZ NOT NULL,
    canceled_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT subscriptions_status_check CHECK (
        status IN (
            'active',
            'trialing',
            'past_due',
            'canceled',
            'expired'
        )
    ),
    CONSTRAINT subscriptions_cycle_check CHECK (
        billing_cycle IN ('monthly', 'quarterly', 'annual')
    ),
    CONSTRAINT subscriptions_amount_positive CHECK (amount >= 0)
);

CREATE INDEX idx_subscriptions_tenant_id ON subscriptions (tenant_id);

CREATE INDEX idx_subscriptions_tenant_status ON subscriptions (tenant_id, status);

CREATE INDEX idx_subscriptions_period_end ON subscriptions (current_period_end);

-- Enable RLS
ALTER TABLE
    subscriptions ENABLE ROW LEVEL SECURITY;

-- RLS policy: users can only see/modify their own tenant's subscriptions
CREATE POLICY subscriptions_tenant_isolation ON subscriptions USING (
    tenant_id = current_setting('app.tenant_id') :: uuid
) WITH CHECK (
    tenant_id = current_setting('app.tenant_id') :: uuid
);

-- ============================================================================
-- INVOICES
-- ============================================================================
CREATE TABLE IF NOT EXISTS invoices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    subscription_id UUID REFERENCES subscriptions(id) ON DELETE
    SET
        NULL,
        invoice_number VARCHAR(50) NOT NULL,
        status VARCHAR(50) NOT NULL DEFAULT 'draft',
        amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
        currency VARCHAR(3) NOT NULL DEFAULT 'usd',
        line_items JSONB NOT NULL DEFAULT '[]',
        due_date TIMESTAMPTZ,
        paid_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CONSTRAINT invoices_status_check CHECK (
            status IN ('draft', 'issued', 'paid', 'overdue', 'void')
        ),
        CONSTRAINT invoices_amount_positive CHECK (amount >= 0),
        CONSTRAINT invoices_number_unique UNIQUE (tenant_id, invoice_number)
);

CREATE INDEX idx_invoices_tenant_id ON invoices (tenant_id);

CREATE INDEX idx_invoices_tenant_status ON invoices (tenant_id, status);

CREATE INDEX idx_invoices_created_at ON invoices (created_at DESC);

-- Composite index for cursor-based pagination (see list-invoices handler)
CREATE INDEX idx_invoices_pagination ON invoices (tenant_id, created_at DESC, id DESC);

-- Enable RLS
ALTER TABLE
    invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY invoices_tenant_isolation ON invoices USING (
    tenant_id = current_setting('app.tenant_id') :: uuid
) WITH CHECK (
    tenant_id = current_setting('app.tenant_id') :: uuid
);

-- ============================================================================
-- BILLING EVENTS
-- ============================================================================
-- Usage events for metered billing.  Each event has a type, quantity, and
-- payload.  Events are aggregated during invoice generation.
CREATE TABLE IF NOT EXISTS billing_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    event_type VARCHAR(50) NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}',
    quantity NUMERIC(16, 4) NOT NULL DEFAULT 1,
    idempotency_key VARCHAR(255),
    event_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT events_type_check CHECK (
        event_type IN (
            'api_call',
            'storage_used',
            'compute_time',
            'custom'
        )
    ),
    CONSTRAINT events_quantity_positive CHECK (quantity >= 0),
    -- Idempotency: unique key per tenant prevents duplicate processing
    CONSTRAINT events_idempotency UNIQUE (tenant_id, idempotency_key)
);

CREATE INDEX idx_events_tenant_id ON billing_events (tenant_id);

CREATE INDEX idx_events_tenant_type ON billing_events (tenant_id, event_type);

CREATE INDEX idx_events_tenant_timestamp ON billing_events (tenant_id, event_timestamp DESC);

-- Index for aggregation queries during invoice generation
CREATE INDEX idx_events_aggregation ON billing_events (tenant_id, event_type, event_timestamp);

-- Enable RLS
ALTER TABLE
    billing_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY events_tenant_isolation ON billing_events USING (
    tenant_id = current_setting('app.tenant_id') :: uuid
) WITH CHECK (
    tenant_id = current_setting('app.tenant_id') :: uuid
);

-- ============================================================================
-- UPDATED_AT TRIGGER
-- ============================================================================
-- Automatically updates the `updated_at` column on every UPDATE.
CREATE
OR REPLACE FUNCTION trigger_set_updated_at() RETURNS TRIGGER AS $ $ BEGIN NEW.updated_at = NOW();

RETURN NEW;

END;

$ $ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at_tenants BEFORE
UPDATE
    ON tenants FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_updated_at_subscriptions BEFORE
UPDATE
    ON subscriptions FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_updated_at_invoices BEFORE
UPDATE
    ON invoices FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();