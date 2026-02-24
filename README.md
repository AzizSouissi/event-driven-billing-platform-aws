# Event-Driven Billing Platform — AWS Infrastructure

Production-ready Terraform foundation for a serverless SaaS billing backend on AWS.

---

## Repository Structure

```text
terraform/
├── bootstrap/              # One-time setup: S3 state bucket + DynamoDB lock table
│   └── main.tf
├── modules/
│   ├── vpc/                # Network layer: VPC, subnets, NAT, SGs, DB subnet group
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── iam/                # IAM roles: Lambda execution, API GW CloudWatch
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── auth/               # Cognito User Pool, App Client, JWT authorizer
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── api/                # REST routes, Lambda functions, throttling, validation
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── events/             # SNS fan-out, SQS queues + DLQs, consumer Lambdas
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── observability/      # Dashboard, alarms, metric filters, alert SNS topic
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── rds/                # Aurora Serverless v2 (PostgreSQL), KMS, monitoring
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── vpc-endpoints/      # Gateway (S3, DynamoDB) + Interface (SQS, etc.)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── waf/                # AWS WAF v2 — API Gateway protection (rate limit, OWASP)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── pre-token/          # Cognito pre-token-generation Lambda (plan tier, features)
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    └── dev/                # Dev environment root module (composes modules)
        ├── backend.tf      # Remote state configuration
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── terraform.tfvars.example

src/
├── shared/                 # Shared libraries used by all handlers
│   ├── db.js               # PostgreSQL connection pool + tenant-scoped queries
│   ├── logger.js           # Structured JSON logging for CloudWatch Insights
│   ├── middleware.js        # JWT extraction, validation, error handling wrapper
│   ├── validation.js        # SSM-backed JSON Schema validation (ajv)
│   ├── idempotency.js      # PostgreSQL-based idempotency guard for SQS consumers
│   ├── sqs-consumer.js     # SQS batch processing middleware with partial failures
│   ├── metrics.js          # CloudWatch EMF custom metrics (zero-latency)
│   └── index.js            # Barrel export
├── handlers/               # Lambda function source code
│   ├── create-tenant/      # POST /v1/tenants — create new tenant (ADMIN only)
│   │   └── index.js
│   ├── create-subscription/# POST /v1/subscriptions — create subscription + SNS publish
│   │   └── index.js
│   ├── list-invoices/      # GET /v1/invoices — paginated invoice listing
│   │   └── index.js
│   ├── ingest-event/       # POST /v1/events — ingest metered billing events
│   │   └── index.js
│   ├── generate-invoice/   # SQS consumer — auto-generate invoice on subscription
│   │   └── index.js
│   ├── send-notification/  # SQS consumer — send email notification
│   │   └── index.js
│   ├── audit-log/          # SQS consumer — append-only audit trail
│   │   └── index.js
│   └── pre-token-generation/ # Cognito trigger — enrich JWT with plan tier + features
│       └── index.js
├── migrations/             # Database schema migrations
│   ├── 001_initial_schema.sql
│   └── 002_event_processing.sql
└── package.json            # Node.js dependencies (pg, aws-sdk, ajv, uuid)
```

---

## Architecture Design Decisions

### 1. VPC & Network Topology

| Component             | Choice         | Rationale                                                                                                                                                               |
| --------------------- | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **VPC CIDR**          | `10.0.0.0/16`  | ~65k IPs; room for growth without re-IP across subnets for Lambda ENIs, RDS, caches, etc.                                                                               |
| **2 Public Subnets**  | `/24` in 2 AZs | Host the NAT Gateway and future ALB. Spread across AZs for HA.                                                                                                          |
| **2 Private Subnets** | `/24` in 2 AZs | Host Lambda ENIs and RDS. Isolated from the internet by design — no IGW route.                                                                                          |
| **Internet Gateway**  | 1 per VPC      | Required for public subnet internet access and NAT GW placement.                                                                                                        |
| **NAT Gateway**       | 1 (dev)        | Lambda inside the VPC needs outbound internet (AWS APIs, SQS, external webhooks). Single NAT saves ~$32/mo in dev; **prod should deploy 1 per AZ** for fault tolerance. |
| **DNS Hostnames**     | Enabled        | Required for RDS endpoint DNS resolution within the VPC.                                                                                                                |

**Why Lambda in the VPC?** Lambda must connect to RDS on a private subnet. VPC placement lets us enforce security-group-level network segmentation. The NAT Gateway provides outbound internet for SDK calls (SQS, S3, Secrets Manager).

### 2. Security Groups — Least Privilege

```text
┌──────────────┐     port 5432     ┌──────────────┐
│  Lambda SG   │ ───────────────▷  │   RDS SG     │
│              │                   │              │
│ egress: all  │                   │ ingress:     │
│ inbound: ─   │                   │  5432 from   │
│              │                   │  Lambda SG   │
└──────────────┘                   │              │
                                   │ egress: VPC  │
                                   │  CIDR only   │
                                   └──────────────┘
```

- **Lambda SG**: No inbound rules (API GW invokes Lambda via the AWS service, not through the VPC ENI). Outbound is open for NAT/AWS API calls.
- **RDS SG**: Ingress _only_ from Lambda SG on port 5432. No CIDR-based rules — this prevents any resource without the Lambda SG from reaching the database. Egress restricted to VPC CIDR (defense-in-depth — RDS doesn't initiate external connections).
- **No public DB access**: RDS lives exclusively in private subnets with no route to the IGW.

### 3. RDS Placement

- Deployed in **private subnets only** via `aws_db_subnet_group`.
- Multi-AZ failover requires subnets in ≥2 AZs (satisfied by our 2 private subnets).
- The DB subnet group is output so downstream RDS resources can reference it directly.

### 4. IAM — Baseline Roles

| Role                  | Trust                      | Policies                                                   | Why                                                                                                                                                            |
| --------------------- | -------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Lambda Execution**  | `lambda.amazonaws.com`     | `AWSLambdaVPCAccessExecutionRole` + scoped CloudWatch Logs | VPC ENI management + logging. Additional per-function policies (RDS IAM auth, Secrets Manager, SQS) should be _attached separately_ to avoid monolithic roles. |
| **API GW CloudWatch** | `apigateway.amazonaws.com` | `AmazonAPIGatewayPushToCloudWatchLogs`                     | Account-level singleton. Linked via `aws_api_gateway_account` so all API stages can write access logs and execution logs.                                      |

Lambda logging is **scoped to a log-group prefix** (`/aws/lambda/billing-platform-dev-*`) rather than `*`, enforcing least privilege even in logging.

### 5. Authentication & Multi-Tenancy (Cognito)

#### Architecture Overview

```text
┌─────────┐   Authorization: Bearer <JWT>   ┌──────────────────┐
│  Client  │ ─────────────────────────────▷  │  API Gateway     │
│ (SPA /   │                                 │  HTTP API        │
│  Mobile) │                                 │                  │
└─────────┘                                  │  JWT Authorizer  │
     │                                       │  ┌────────────┐  │
     │  Auth Code + PKCE                     │  │ Validates:  │  │
     ▼                                       │  │ • signature │  │
┌──────────────┐                             │  │ • exp       │  │
│  Cognito     │  issues JWT with claims:    │  │ • iss       │  │
│  User Pool   │  • sub (user id)            │  │ • aud       │  │
│              │  • custom:tenant_id          │  └────────────┘  │
│  Groups:     │  • cognito:groups            └────────┬─────────┘
│  • ADMIN     │                                       │
│  • USER      │                                       ▼
└──────────────┘                             ┌──────────────────┐
                                             │  Lambda Function │
                                             │                  │
                                             │  Reads claims:   │
                                             │  • tenant_id     │
                                             │  • groups        │
                                             │  Scopes DB query │
                                             └──────────────────┘
```

#### How JWT Validation Works

When a client sends a request with `Authorization: Bearer <token>`, API Gateway's built-in JWT authorizer performs these checks **before** the request reaches Lambda:

1. **Signature verification** — Downloads the JSON Web Key Set (JWKS) from `https://cognito-idp.<region>.amazonaws.com/<pool-id>/.well-known/jwks.json` and verifies the token's RS256 signature against the public key. This proves the token was issued by Cognito and has not been tampered with.
2. **Expiration check** — Rejects tokens where `exp < current_time`. Access tokens default to 60 minutes.
3. **Issuer validation** — Confirms the `iss` claim matches the configured User Pool URL. Prevents tokens from other pools or identity providers from being accepted.
4. **Audience validation** — Confirms the `aud` (ID token) or `client_id` (access token) claim matches the App Client ID. Prevents tokens issued for a different application from being reused.

If **any** check fails, API Gateway returns `401 Unauthorized` immediately — Lambda is never invoked, saving cost and reducing attack surface.

After validation, the decoded claims are injected into the Lambda event at `requestContext.authorizer.jwt.claims`, making `custom:tenant_id` and `cognito:groups` available without any custom parsing.

#### How Tenant Isolation Is Enforced

Tenant isolation operates at **three layers**:

| Layer         | Mechanism                                                    | Enforcement Point          |
| ------------- | ------------------------------------------------------------ | -------------------------- |
| **Identity**  | `custom:tenant_id` is immutable and admin-only writable      | Cognito User Pool schema   |
| **Transport** | JWT carries `tenant_id` as a signed claim — cannot be forged | API Gateway JWT authorizer |
| **Data**      | Every DB query includes `WHERE tenant_id = <claim>`          | Lambda application code    |

**Why immutable `tenant_id`?** The attribute is set once at user creation by an admin or backend service. Users cannot modify it via the Cognito UpdateUserAttributes API because `mutable = false` in the schema and `custom:tenant_id` is excluded from the App Client's `write_attributes`. This prevents a user from changing their own tenant assignment.

**Why not a pool per tenant?** Cognito has a default quota of 1,000 User Pools per account. A pool-per-tenant architecture breaks at scale and complicates cross-tenant admin operations. A single pool with a `tenant_id` claim scales to millions of users with no quota concern.

**Row-level security pattern** (Lambda pseudocode):

```python
def handler(event, context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    tenant_id = claims["custom:tenant_id"]
    groups = claims.get("cognito:groups", [])

    # Every query is scoped — no tenant can see another's data
    invoices = db.query(
        "SELECT * FROM invoices WHERE tenant_id = %s",
        [tenant_id]
    )

    # Role-based access
    if "ADMIN" not in groups:
        raise ForbiddenError("Admin access required")
```

#### How This Design Scales for SaaS

| Concern                 | Solution                                                             | Scale Limit                     |
| ----------------------- | -------------------------------------------------------------------- | ------------------------------- |
| **User volume**         | Single Cognito pool, 40M users per pool                              | 40,000,000 users                |
| **Tenant count**        | `tenant_id` claim, not separate pools                                | Unlimited (attribute value)     |
| **Auth latency**        | API GW JWT authorizer (no Lambda cold start)                         | Sub-millisecond validation      |
| **Role management**     | Cognito Groups (ADMIN, USER) in token claims                         | Add groups without redeployment |
| **Token customization** | Pre-token-generation Lambda trigger (optional)                       | Inject plan tier, feature flags |
| **Multi-region**        | Deploy separate pools per region, federate via custom domain         | Per-region isolation            |
| **Machine-to-machine**  | Resource Server with custom scopes (`billing.read`, `billing.write`) | Client credentials flow         |
| **New environments**    | Clone `environments/dev` → `environments/prod`                       | Same module, different vars     |

#### Cognito Resources Created

| Resource                 | Purpose                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------- |
| **User Pool**            | Central identity store with email/password auth, password policy, and `custom:tenant_id` |
| **App Client**           | Public client (no secret) for SPA/mobile — Authorization Code + PKCE                     |
| **User Pool Domain**     | Hosted UI endpoint for login/signup/forgot-password flows                                |
| **Groups (ADMIN, USER)** | RBAC via `cognito:groups` claim in JWT                                                   |
| **Resource Server**      | Custom OAuth scopes for future M2M authorization                                         |
| **HTTP API**             | API Gateway v2 with CORS, access logging, auto-deploy stage                              |
| **JWT Authorizer**       | Validates Cognito tokens on every request before Lambda invocation                       |

### 6. REST API — Routes, Throttling & Validation

#### Endpoint Map

```text
HTTP API (API Gateway v2)
│
├── JWT Authorizer (Cognito)          ← every route requires valid token
│
├── Stage: v1                         ← URI-path versioning
│   ├── POST /v1/tenants              → create-tenant       (burst:  20, rate:  10/s)
│   ├── POST /v1/subscriptions        → create-subscription (burst:  50, rate:  25/s)
│   ├── GET  /v1/invoices             → list-invoices       (burst: 200, rate: 100/s)
│   └── POST /v1/events               → ingest-event        (burst: 500, rate: 200/s)
│
└── Stage: $default                   ← auth module (Cognito hosted UI callbacks)
```

Each route maps to a dedicated Lambda function running inside the VPC with access to RDS via the Lambda security group.

#### How Throttling Protects Backend Services

Throttling operates at **two levels**, forming a cascading protection shield:

```text
                  Internet Traffic
                       │
                       ▼
             ┌─────────────────┐
             │  Stage Default   │  100 burst / 50 req/s
             │  (safety net)    │  ← catches unthrottled routes
             └────────┬────────┘
                      │
        ┌─────────────┼─────────────────┐
        ▼             ▼                 ▼
  ┌───────────┐ ┌───────────┐    ┌───────────┐
  │ /tenants  │ │ /invoices │    │ /events   │
  │ 20 burst  │ │ 200 burst │    │ 500 burst │
  │ 10 req/s  │ │ 100 req/s │    │ 200 req/s │
  └─────┬─────┘ └─────┬─────┘    └─────┬─────┘
        │             │                │
        ▼             ▼                ▼
  ┌─────────────────────────────────────────┐
  │  Lambda Concurrent Executions           │
  │  (account limit: 1,000 default)         │
  └─────────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────────────────┐
  │  RDS Connection Pool                    │
  │  (Aurora max: ~1,000 connections)       │
  └─────────────────────────────────────────┘
```

**Why per-route limits differ:**

| Route                    | Burst | Rate  | Rationale                                 |
| ------------------------ | ----- | ----- | ----------------------------------------- |
| `POST /v1/tenants`       | 20    | 10/s  | Admin-only, rare, creates heavy resources |
| `POST /v1/subscriptions` | 50    | 25/s  | Moderate — tied to billing state changes  |
| `GET /v1/invoices`       | 200   | 100/s | High-frequency read, cacheable            |
| `POST /v1/events`        | 500   | 200/s | Event ingestion is bursty by nature       |

**What happens when throttled:** API Gateway returns `429 Too Many Requests` with a `Retry-After` header. The client should implement exponential backoff. Lambda is never invoked, so **no cost is incurred** for throttled requests.

**Defence-in-depth chain:**

1. API Gateway throttle → prevents Lambda concurrency exhaustion
2. Lambda reserved concurrency (set per-function in prod) → prevents one function from starving others
3. RDS Proxy (future) → connection pooling prevents DB connection exhaustion

#### Logging Best Practices

Access logs are **structured JSON** with fields designed for CloudWatch Insights queries:

```json
{
  "requestId": "abc-123",
  "requestTime": "24/Feb/2026:12:00:00 +0000",
  "ip": "203.0.113.42",
  "userAgent": "Mozilla/5.0",
  "httpMethod": "POST",
  "routeKey": "POST /v1/events",
  "path": "/v1/events",
  "status": "200",
  "responseLatencyMs": "45",
  "integrationLatency": "42",
  "tenantId": "tenant-abc",
  "userGroups": "[ADMIN]",
  "sub": "user-uuid",
  "error": "",
  "errorType": ""
}
```

**Key practices implemented:**

| Practice                | Implementation                                                                               |
| ----------------------- | -------------------------------------------------------------------------------------------- |
| **Structured format**   | JSON — queryable with CloudWatch Insights, parseable by any log aggregator                   |
| **Request correlation** | `requestId` + `extendedId` trace a request end-to-end                                        |
| **Tenant attribution**  | `tenantId` in every log line — enables per-tenant dashboards and cost allocation             |
| **Latency breakdown**   | `responseLatencyMs` (total) vs `integrationLatency` (Lambda only) — isolates API GW overhead |
| **Error capture**       | `error` + `errorType` populated on 4xx/5xx — no need to dig into execution logs              |
| **Retention policy**    | Configurable per environment (dev: 30 days, prod: 90+ days)                                  |
| **Separate log groups** | One per Lambda function + one for API access logs — independent retention and access control |

**Example CloudWatch Insights query** — find slow requests per tenant:

```sql
fields @timestamp, tenantId, routeKey, responseLatencyMs
| filter responseLatencyMs > 1000
| sort responseLatencyMs desc
| limit 50
```

#### Request Validation Strategy

HTTP API v2 doesn't support built-in request validators like REST API v1. We use a **schema-in-SSM** pattern:

1. JSON Schemas are defined in Terraform and stored as SSM parameters
2. Lambda loads schemas on cold start (cached in memory)
3. A shared validation middleware validates `event.body` against the schema
4. Invalid requests get `400 Bad Request` with field-level error details

**Benefits over hardcoded validation:**

- Schemas are version-controlled alongside infrastructure
- Schema updates don't require Lambda redeployment
- Consistent error format across all endpoints
- Schemas are reusable (e.g., frontend can fetch them for client-side validation)

#### API Versioning Strategy

We use **URI-path versioning** (`/v1/...`) via API Gateway stages:

| Strategy                             | Pros                                | Cons                                   | Our Choice |
| ------------------------------------ | ----------------------------------- | -------------------------------------- | ---------- |
| **URI path** (`/v1/`)                | Explicit, cacheable, simple routing | URL changes on version bump            | **Yes**    |
| **Header** (`Accept-Version: v1`)    | Clean URLs                          | Not cacheable by CDN, hidden from logs | No         |
| **Query param** (`?version=1`)       | Easy to test                        | Pollutes cache keys, non-standard      | No         |
| **Subdomain** (`v1.api.example.com`) | Full isolation                      | DNS + TLS cert per version, complex    | No         |

**Why URI path wins for SaaS billing:**

- API Gateway stages map naturally to `/v1`, `/v2` — no custom routing logic
- CDN and WAF rules can target path prefixes
- Access logs show the version in `routeKey` — instant observability
- Breaking changes get a new stage (`/v2`) with independent throttling and Lambda versions
- Old versions can be sunset by removing the stage

**Migration path:** When `/v2` is needed, create a new API module instance with `stage_name = "v2"` pointing to new Lambda versions. Both stages run concurrently on the same HTTP API.

### 7. Terraform Remote Backend

| Component            | Purpose                                                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **S3 Bucket**        | Stores `terraform.tfstate` with versioning (rollback), KMS encryption (at-rest security), and public-access block.        |
| **DynamoDB Table**   | `LockID` hash key provides distributed locking to prevent concurrent `terraform apply` from corrupting state.             |
| **Bootstrap Script** | Solves the chicken-and-egg problem: the bucket must exist before `terraform init` can use it. Runs once with local state. |

### 8. Modular Structure

```text
modules/vpc   → Reusable across dev/staging/prod (pass different CIDRs, NAT count)
modules/iam   → Reusable baseline roles; per-function policies added downstream
modules/auth  → Cognito + API GW; swap callback URLs and security mode per env
modules/api   → Routes + Lambda + throttling; per-env throttle limits and schemas
environments/ → Per-env root modules that compose modules with env-specific vars
```

**Why modules?**

- **DRY**: One source of truth for network/IAM logic.
- **Blast radius**: Changes are scoped — a VPC update doesn't trigger IAM re-evaluation.
- **Testability**: Modules can be unit-tested with `terraform plan` in isolation.
- **Team scaling**: Different teams can own different modules.

### 9. Lambda Function Design

#### Connection Pooling

| Decision                    | Implementation                                       | Rationale                                                                                            |
| --------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **Module-level singleton**  | `pg.Pool` created outside handler, stored in `_pool` | Lambda reuses the execution environment; pool persists across warm invocations (~5ms vs ~100ms cold) |
| **max: 2 connections**      | Per Lambda container                                 | 100 concurrent containers = 200 connections; keeps within RDS limits                                 |
| **Idle timeout: 60s**       | `idleTimeoutMillis: 60000`                           | Lambda containers freeze after ~5-15 min; short timeout prevents stale connections                   |
| **Statement timeout: 8s**   | `statement_timeout: 8000`                            | Lambda timeout is 10s; queries abort before function timeout, allowing clean error response          |
| **Secrets Manager caching** | Credentials fetched on cold start, cached in-memory  | Avoids ~50ms Secrets Manager call on every invocation; auto-refreshes on next cold start             |

#### Cold Start Mitigation

| Phase                 | Duration       | Mitigation                             |
| --------------------- | -------------- | -------------------------------------- |
| Container init        | ~300ms         | N/A (AWS managed)                      |
| Secrets Manager fetch | ~50ms          | Cached after first call                |
| DB connection         | ~50-100ms      | Pool persists across warm invocations  |
| SSM schema fetch      | ~50ms          | Compiled validator cached in-memory    |
| **Total cold start**  | **~450-500ms** | **Warm invocations: ~5-10ms overhead** |

For latency-critical paths, enable **Provisioned Concurrency** (e.g., 5 warm containers for `ingest-event`).

#### DB Access Security (Defense in Depth)

```text
Layer 1: VPC — Lambda in private subnet, RDS SG allows port 5432 only from Lambda SG
Layer 2: Secrets Manager — Credentials encrypted (KMS), rotatable, never in env vars or code
Layer 3: SSL/TLS — All connections use TLS (pg.Pool ssl: { rejectUnauthorized: false } for RDS CA)
Layer 4: IAM Policy — Lambda role scoped to read only its own secret ARN path
Layer 5: Row-Level Security — PostgreSQL RLS policies filter by app.tenant_id session variable
Layer 6: Application — queryWithTenant() sets tenant context before every query (belt + suspenders)
```

#### Cross-Tenant Data Leakage Prevention

**Problem:** In a multi-tenant DB, a bug in one handler could expose Tenant A's data to Tenant B.

**Solution — 3-layer defense:**

1. **Application layer**: Every query goes through `queryWithTenant(tenantId, sql, params)` which extracts `tenantId` from the JWT `custom:tenant_id` claim. The tenant ID is NEVER taken from the request body.

2. **Database layer (RLS)**: PostgreSQL Row-Level Security policies automatically filter rows:

   ```sql
   CREATE POLICY subscriptions_tenant_isolation ON subscriptions
     USING (tenant_id = current_setting('app.tenant_id')::uuid);
   ```

   Even if application code omits a `WHERE tenant_id = $1` clause, the DB returns only the current tenant's rows.

3. **Transaction scoping**: `SET LOCAL` scopes the tenant variable to the current transaction, so it cannot leak to other requests sharing the same connection.

#### Structured Logging

All handlers emit JSON logs for CloudWatch Insights:

```json
{
  "timestamp": "2024-01-15T10:30:00.000Z",
  "level": "INFO",
  "message": "Subscription created successfully",
  "functionName": "billing-platform-dev-create-subscription",
  "requestId": "abc-123",
  "tenantId": "tenant-uuid",
  "userId": "user-uuid",
  "subscriptionId": "sub-uuid",
  "planId": "pro",
  "billingCycle": "monthly"
}
```

Query examples:

```text
fields @timestamp, level, message, tenantId
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

### 10. Event-Driven Architecture (SNS Fan-Out)

#### Why Event-Driven?

Synchronous request-response flows couple producers to consumers. When a subscription is created, the API handler would need to know about invoicing, notifications, _and_ audit logging — violating the Single Responsibility Principle and making the system fragile. An event-driven design solves this with:

| Benefit                  | How It Applies                                                                                                     |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| **Loose coupling**       | `create-subscription` publishes a single SNS message. It doesn't know (or care) who consumes it.                   |
| **Independent scaling**  | Each SQS queue + Lambda pair scales independently based on its own traffic pattern and concurrency.                |
| **Failure isolation**    | A failing notification sender doesn't block invoice generation — each consumer retries independently.              |
| **Extensibility**        | Adding a new consumer (e.g., analytics, webhook relay) requires only a new SQS subscription — no producer changes. |
| **Eventual consistency** | Consumers process at their own pace; temporary spikes are absorbed by SQS buffering.                               |

#### Event Flow Topology

```text
┌──────────────────────┐
│  create-subscription │   POST /v1/subscriptions
│  (API Lambda)        │
└──────────┬───────────┘
           │ SNS Publish
           ▼
┌──────────────────────┐
│  SNS Topic           │   subscription-events
│  (KMS encrypted)     │
└──┬───────┬───────┬───┘
   │       │       │       SNS → SQS fan-out (raw message delivery)
   ▼       ▼       ▼
┌──────┐ ┌──────┐ ┌──────┐
│ SQS  │ │ SQS  │ │ SQS  │   Processing queues (SSE encrypted)
│invoke│ │notify│ │audit │
└──┬───┘ └──┬───┘ └──┬───┘
   │        │        │        SQS → Lambda event source mapping
   ▼        ▼        ▼
┌──────┐ ┌──────┐ ┌──────┐
│ λ    │ │ λ    │ │ λ    │   Consumer Lambdas
│Invoice│ │Email │ │Audit │
└──┬───┘ └──┬───┘ └──┬───┘
   │        │        │        On exhausted retries → DLQ
   ▼        ▼        ▼
┌──────┐ ┌──────┐ ┌──────┐
│ DLQ  │ │ DLQ  │ │ DLQ  │   Dead-letter queues (14-day retention)
│      │ │      │ │      │   CloudWatch alarm when messages arrive
└──────┘ └──────┘ └──────┘
```

#### SNS Message Format

The `create-subscription` handler publishes a structured event:

```json
{
  "eventType": "subscription.created",
  "tenantId": "uuid",
  "tenantName": "Acme Corp",
  "tenantEmail": "admin@acme.com",
  "subscriptionId": "uuid",
  "planId": "professional",
  "billingCycle": "monthly",
  "amount": 4999,
  "currency": "usd",
  "periodStart": "2024-01-01T00:00:00.000Z",
  "periodEnd": "2024-02-01T00:00:00.000Z",
  "timestamp": "2024-01-01T12:00:00.000Z"
}
```

`MessageAttributes` include `eventType` and `tenantId` for future SNS filter policy support.

#### Retry Strategy & Dead-Letter Queues

Each processing queue is configured with a **redrive policy** that moves messages to a DLQ after a configurable number of receive attempts:

| Consumer              | Max Retries | Visibility Timeout | Batch Size | Rationale                                              |
| --------------------- | ----------- | ------------------ | ---------- | ------------------------------------------------------ |
| **generate-invoice**  | 5           | 180s (6× timeout)  | 1          | DB write must be idempotent; retry generously          |
| **send-notification** | 3           | 90s (6× timeout)   | 5          | External SES call; fail fast to avoid duplicate emails |
| **audit-log**         | 5           | 90s (6× timeout)   | 10         | Append-only; safe to batch and retry aggressively      |

**Visibility timeout** is set to 6× the Lambda timeout to prevent messages from becoming visible again while a slow invocation is still processing.

**DLQ retention** is 14 days, providing ample time for on-call investigation. A **CloudWatch alarm** fires when any DLQ has `ApproximateNumberOfMessagesVisible > 0`, enabling immediate alerting.

#### Idempotency — Preventing Duplicate Processing

SQS guarantees **at-least-once delivery**, meaning a message may be delivered more than once (e.g., after a visibility timeout expiry or during infrastructure retries). Without idempotency, this would create duplicate invoices or duplicate audit entries.

**Implementation** (PostgreSQL-based):

```text
┌─────────────────────────────────────────────────────────────────┐
│                    SQS Consumer Middleware                       │
│                                                                 │
│  1. Parse SQS record → extract messageId                        │
│  2. Build idempotency key: "{consumer}:{messageId}"             │
│  3. INSERT INTO processed_events (idempotency_key, consumer)    │
│     → If UNIQUE violation → skip (already processed)            │
│  4. Execute business logic (generate invoice / send email / …)  │
│  5. UPDATE processed_events SET status = 'completed'            │
│  6. On failure → DELETE lock row → message returns to queue     │
│                                                                 │
│  Returns: { batchItemFailures: [...] }                          │
│           (partial batch failure reporting)                      │
└─────────────────────────────────────────────────────────────────┘
```

The `processed_events` table uses a **UNIQUE constraint** on `idempotency_key`. The INSERT acts as an atomic lock — concurrent duplicate deliveries will hit the constraint and be safely skipped.

#### Partial Batch Failure Reporting

Lambda event source mappings are configured with `FunctionResponseTypes = ["ReportBatchItemFailures"]`. This means:

- If 1 message in a batch of 10 fails, only that 1 message is retried
- The other 9 are deleted from the queue (acknowledged as processed)
- Without this, _all 10_ would be retried, causing unnecessary reprocessing

The `sqs-consumer.js` middleware returns `{ batchItemFailures: [{ itemIdentifier: messageId }] }` for any failed records.

#### Failure Handling Flow

```text
Message arrives in SQS
        │
        ▼
┌─ Idempotency check ─┐
│  Already processed?  │──── YES ──▶ Skip (acknowledge)
└──────────┬───────────┘
           │ NO
           ▼
   Execute business logic
        │         │
     SUCCESS    FAILURE
        │         │
        ▼         ▼
  Mark complete   Release lock
  in DB           (DELETE row)
                     │
                     ▼
            Message returns to queue
            (visibility timeout)
                     │
                     ▼
            Retry up to maxReceiveCount
                     │
                     ▼
            Exhausted → DLQ
                     │
                     ▼
            CloudWatch Alarm fires
```

### 11. Observability — CloudWatch Metrics, Alarms & Dashboard

#### Logs vs. Metrics — When to Use Each

| Aspect        | Logs                                             | Metrics                                           |
| ------------- | ------------------------------------------------ | ------------------------------------------------- |
| **What**      | Discrete events with full context (JSON objects) | Numeric time-series data points                   |
| **When**      | Debugging, audit trails, error details           | Dashboards, alerting, trend analysis              |
| **Cost**      | $0.50/GB ingested, $0.03/GB stored               | $0.30/metric/month (custom), free for AWS-managed |
| **Latency**   | Near-real-time (seconds)                         | 1-minute or 1-second resolution                   |
| **Query**     | CloudWatch Logs Insights (ad-hoc, powerful)      | Metric Math (aggregate, fast)                     |
| **Retention** | Configurable (30 days dev, 365+ prod)            | 15 months automatic (no config)                   |
| **Best for**  | "What happened to request X?"                    | "Is the system healthy right now?"                |

**Rule of thumb**: Logs tell you _why_ something broke. Metrics tell you _that_ something is breaking.

#### Structured Logging Strategy

Every Lambda emits structured JSON via the shared `logger.js`. No free-text logs — this enables CloudWatch Logs Insights queries on any field:

```json
{
  "timestamp": "2024-01-15T12:00:00.000Z",
  "level": "INFO",
  "message": "Subscription created successfully",
  "functionName": "billing-platform-dev-create-subscription",
  "requestId": "abc-123",
  "tenantId": "tenant-uuid",
  "userId": "user-uuid",
  "subscriptionId": "sub-uuid",
  "planId": "pro",
  "billingCycle": "monthly",
  "amount": 99
}
```

Key queries for operations:

```text
# Error rate by function (last 1h)
filter level = "ERROR"
| stats count(*) as errors by functionName
| sort errors desc

# P99 request latency per endpoint
filter message = "Request completed"
| stats pct(statusCode, 99) by path

# Slowest tenants (possible noisy neighbors)
filter message = "Request completed"
| stats avg(duration) as avgMs, count(*) as requests by tenantId
| sort avgMs desc | limit 10
```

#### Custom Metrics via Embedded Metric Format (EMF)

Custom metrics use CloudWatch **Embedded Metric Format** — a specially-structured JSON line written to stdout that CloudWatch automatically extracts as a metric.

**Why EMF instead of PutMetricData API?**

| Approach                   | Latency Impact         | Cost                               | Complexity            |
| -------------------------- | ---------------------- | ---------------------------------- | --------------------- |
| **PutMetricData API**      | +50-100ms per call     | $0.01/1K requests                  | Requires SDK + IAM    |
| **Embedded Metric Format** | 0ms (writes to stdout) | Free (uses existing log ingestion) | Just a JSON structure |

Custom metrics emitted:

| Metric                    | Type     | Unit          | Emitted By          | Purpose                            |
| ------------------------- | -------- | ------------- | ------------------- | ---------------------------------- |
| `invoice_generation_time` | Timer    | Milliseconds  | generate-invoice    | Track invoice latency P50/P90/P99  |
| `subscription_count`      | Counter  | Count         | create-subscription | New subscriptions per period       |
| `subscription_revenue`    | Business | Count (cents) | create-subscription | Revenue per subscription           |
| `invoice_amount`          | Business | Count (cents) | generate-invoice    | Invoice amounts for billing health |

Usage in handler code:

```javascript
const {
  startTimer,
  incrementCounter,
  recordBusinessMetric,
} = require("../../shared/metrics");

// Timer: automatically emits invoice_generation_time on stop
const stopTimer = startTimer("invoice_generation", { TenantId: tenantId });
// ... generate invoice ...
stopTimer(); // Records duration in ms

// Counter: increment subscription_count by 1
incrementCounter("subscription_count", 1, { PlanId: "pro" });

// Business KPI: revenue per invoice
recordBusinessMetric("invoice_amount", 9900, "Count", { PlanId: "pro" });
```

#### Alarm Strategy — Preventing Alert Fatigue

Alert fatigue is the #1 cause of missed incidents in SaaS operations. The alarm configuration follows three rules:

##### Rule 1 — Require sustained breaching (never single-datapoint alarms)

```text
Lambda error rate:  > 5% for 3 consecutive 5-min periods = 15 minutes
RDS CPU:            > 70% for 3 consecutive 5-min periods = 15 minutes
```

A single spike (cold start, one bad request, end-of-month batch) won't page anyone. Only persistent issues trigger.

##### Rule 2 — Use percentages, not absolute counts

100 errors out of 1,000,000 requests = 0.01% (healthy). 100 errors out of 200 requests = 50% (crisis). The Lambda error rate alarm uses metric math `(Errors / Invocations * 100)` to normalize for traffic volume.

##### Rule 3 — Severity tiers with routing

| Severity     | Alarm                                            | Action                                               |
| ------------ | ------------------------------------------------ | ---------------------------------------------------- |
| **Critical** | Lambda error rate > 5%, API 5xx rate             | SNS → PagerDuty (pages on-call)                      |
| **Warning**  | RDS CPU > 70%, Lambda throttles, RDS connections | SNS → Slack (no page, investigate next business day) |
| **Info**     | DLQ messages > 0, storage low                    | SNS → Slack (awareness only)                         |

All alarms publish to a single SNS topic. Add PagerDuty, Slack, or OpsGenie subscriptions to route by severity.

#### Alarms Configured

| Alarm             | Metric              | Threshold   | Periods  | Significance                  |
| ----------------- | ------------------- | ----------- | -------- | ----------------------------- |
| Lambda error rate | Errors/Invocations  | > 5%        | 3 × 5min | Core reliability SLI          |
| RDS CPU high      | CPUUtilization      | > 70%       | 3 × 5min | Database capacity planning    |
| RDS storage low   | FreeStorageSpace    | < 5 GB      | 1 × 5min | Prevent disk full outage      |
| RDS connections   | DatabaseConnections | > 80        | 2 × 5min | Lambda scaling risk           |
| Lambda throttles  | Throttles           | > 0         | 2 × 5min | Concurrency limit hit         |
| API 5xx rate      | 5xx                 | > 10/period | 3 × 5min | Server errors seen by clients |

#### CloudWatch Dashboard Layout

The `billing-platform-dev-operations` dashboard has five rows:

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Row 1: API Performance                                              │
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                 │
│ │ Latency      │ │ Request      │ │ Error Rates  │                 │
│ │ P50/P90/P99  │ │ Count        │ │ 4xx / 5xx    │                 │
│ └──────────────┘ └──────────────┘ └──────────────┘                 │
├─────────────────────────────────────────────────────────────────────┤
│ Row 2: Lambda Performance                                           │
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                 │
│ │ Error Rate % │ │ Duration P90 │ │ Concurrent   │                 │
│ │ (per func)   │ │ (per func)   │ │ Executions   │                 │
│ └──────────────┘ └──────────────┘ └──────────────┘                 │
├─────────────────────────────────────────────────────────────────────┤
│ Row 3: Business KPIs                                                │
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                 │
│ │ Invoice Gen  │ │ Subscriptions│ │ Revenue per  │                 │
│ │ Time         │ │ Created      │ │ Invoice      │                 │
│ └──────────────┘ └──────────────┘ └──────────────┘                 │
├─────────────────────────────────────────────────────────────────────┤
│ Row 4: Event Processing & Queues                                    │
│ ┌──────────────────────┐ ┌──────────────────────┐                   │
│ │ SQS Messages         │ │ DLQ Message Count    │                   │
│ │ In Flight            │ │ (should be 0)        │                   │
│ └──────────────────────┘ └──────────────────────┘                   │
├─────────────────────────────────────────────────────────────────────┤
│ Row 5: Database (when RDS module is added)                          │
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                 │
│ │ RDS CPU %    │ │ DB           │ │ Free Storage │                 │
│ │              │ │ Connections  │ │ Space        │                 │
│ └──────────────┘ └──────────────┘ └──────────────┘                 │
└─────────────────────────────────────────────────────────────────────┘
```

#### Monitoring Best Practices for SaaS Systems

##### The Four Golden Signals (Google SRE book)

Every monitored service should track these four signals:

| Signal         | What to Measure             | Our Implementation                               |
| -------------- | --------------------------- | ------------------------------------------------ |
| **Latency**    | Time to serve a request     | API Gateway P50/P90/P99, invoice_generation_time |
| **Traffic**    | Demand on the system        | API request count, subscription_count            |
| **Errors**     | Rate of failed requests     | Lambda error rate %, 4xx/5xx counts              |
| **Saturation** | System resource utilization | RDS CPU, connections, Lambda concurrency         |

##### SLI → SLO → SLA Pipeline

- **SLI** (Service Level Indicator): Measurable — "P99 API latency is 450ms"
- **SLO** (Objective): Target — "P99 API latency < 500ms, 99.9% of the time"
- **SLA** (Agreement): Contractual — "If P99 > 1s for > 0.1% of monthly minutes, credit applied"

Start with SLIs (we have them via metrics), define SLOs internally, then negotiate SLAs with customers.

##### Tenant-Aware Monitoring

Multi-tenant SaaS requires per-tenant visibility. Our custom metrics include `TenantId` as a dimension. This enables:

- Identifying noisy neighbors (one tenant consuming disproportionate resources)
- Per-tenant SLA reporting
- Capacity planning based on tenant growth patterns

##### Cost-Effective Observability

| Practice                                     | Saving                                 |
| -------------------------------------------- | -------------------------------------- |
| EMF instead of PutMetricData API             | ~$0/month (vs. $10+/month at scale)    |
| Log retention: 30 days dev, 90+ prod         | Avoid 365-day default ($0.03/GB/month) |
| Metric filters instead of Lambda metrics SDK | No extra API calls                     |
| Single alarm SNS topic, route by severity    | Fewer SNS topics to manage             |

### 12. Aurora Serverless v2 — Managed PostgreSQL

#### Why Aurora Serverless v2?

| Requirement                  | Aurora Serverless v2 Solution                                      |
| ---------------------------- | ------------------------------------------------------------------ |
| **Variable traffic**         | Auto-scales 0.5–128 ACUs in seconds (billing cycles = big spikes)  |
| **Cost efficiency**          | Pay per ACU-hour consumed; scales to 0.5 ACU during idle dev hours |
| **PostgreSQL compatibility** | Standard PostgreSQL 15 — RLS, JSONB, uuid-ossp, pgcrypto all work  |
| **Multi-AZ HA**              | Writer + optional readers for automatic failover                   |
| **No capacity planning**     | No instance type selection or manual scaling triggers              |
| **Managed secrets**          | Secrets Manager auto-generates and can rotate the master password  |

#### Aurora vs. Standard RDS vs. Serverless v1

| Feature                  | Standard RDS             | Aurora Serverless v1    | Aurora Serverless v2               |
| ------------------------ | ------------------------ | ----------------------- | ---------------------------------- |
| Scaling                  | Manual (change instance) | Auto (coarse, v1 ACUs)  | Auto (fine-grained, 0.5 ACU steps) |
| Scale time               | Minutes (reboot)         | 30s–2min (cold restart) | Seconds (in-place)                 |
| Connections during scale | May drop                 | Dropped                 | Maintained                         |
| Min cost (dev)           | ~$13/mo (db.t4g.micro)   | $0 (can pause to 0)     | ~$43/mo (0.5 ACU always on)        |
| Prod readiness           | Full                     | Limited (v1 deprecated) | Full                               |
| Read replicas            | Yes                      | No                      | Yes                                |
| Performance Insights     | Yes                      | No                      | Yes                                |

**Trade-off**: Aurora Serverless v2 cannot scale to 0 ACU (minimum 0.5). For dev environments where cost is critical, standard `db.t4g.micro` is cheaper. For prod and staging, Serverless v2 is the clear winner.

#### Encryption & Security

```text
┌──────────────────────────────────────────────────────────────────────┐
│                    Defense-in-Depth Layers                            │
│                                                                      │
│  1. VPC Isolation    — Private subnets only, no public access        │
│  2. Security Group   — Port 5432 from Lambda SG only                 │
│  3. TLS Enforcement  — rds.force_ssl = 1 (parameter group)           │
│  4. KMS Encryption   — Storage + secrets encrypted with CMK          │
│  5. Secrets Manager  — Auto-managed master password, rotatable       │
│  6. IAM DB Auth      — Enabled for future token-based access         │
│  7. RLS Policies     — Row-Level Security at the PostgreSQL level    │
│  8. Statement Timeout— 30s DB-level, 8s app-level (prevents runaway) │
└──────────────────────────────────────────────────────────────────────┘
```

#### Monitoring Built-In

| Feature                  | Configuration            | Purpose                                       |
| ------------------------ | ------------------------ | --------------------------------------------- |
| **Performance Insights** | 7-day free retention     | Top SQL queries, wait events, lock contention |
| **Enhanced Monitoring**  | 60s interval             | OS-level CPU, memory, disk I/O per process    |
| **PostgreSQL Logs**      | Exported to CloudWatch   | Slow queries (>1s), connection events, errors |
| **pg_stat_statements**   | Preloaded extension      | Cumulative query execution stats              |
| **CloudWatch Alarms**    | Via observability module | CPU >70%, connections >80, storage <5GB       |

#### Scaling Configuration

| Environment | Min ACU | Max ACU | Readers | Backup  | Deletion Protection |
| ----------- | ------- | ------- | ------- | ------- | ------------------- |
| **Dev**     | 0.5     | 4       | 0       | 7 days  | Off                 |
| **Staging** | 0.5     | 8       | 1       | 14 days | On                  |
| **Prod**    | 2       | 32      | 2+      | 35 days | On                  |

One ACU = ~2 GB RAM + proportional CPU. At 0.5 ACU, the instance has ~1 GB RAM — sufficient for dev workloads with low connection counts.

### 13. VPC Endpoints — Reducing NAT Gateway Costs

#### The NAT Cost Problem

All AWS API traffic from Lambda in a private subnet routes through the NAT Gateway. NAT charges $0.045/GB for data processing — this adds up for high-throughput services:

```text
Without VPC Endpoints:
┌─────────┐     AWS APIs     ┌───────────┐     Internet     ┌─────────────┐
│ Lambda  │ ──────────────▷  │ NAT GW    │ ──────────────▷  │ SQS/S3/CW   │
│ (VPC)   │    $0.045/GB     │ ($32/mo)  │    $0.045/GB     │ Endpoints   │
└─────────┘                  └───────────┘                  └─────────────┘

With VPC Endpoints:
┌─────────┐     Private      ┌─────────────┐
│ Lambda  │ ──────────────▷  │ VPC Endpoint │  (stays on AWS backbone)
│ (VPC)   │    Free (GW)     │ S3 / DynDB   │
└─────────┘    or $0.01/GB   └─────────────┘
               (Interface)
```

#### Endpoints Configured

| Endpoint            | Type      | Cost      | Traffic Routed                                               |
| ------------------- | --------- | --------- | ------------------------------------------------------------ |
| **S3**              | Gateway   | Free      | Lambda deploy packages, CloudWatch log delivery, data export |
| **DynamoDB**        | Gateway   | Free      | Terraform state locking, future session/cache store          |
| **SQS**             | Interface | ~$7.20/mo | Event source mapping polls, Lambda-to-SQS sends              |
| **Secrets Manager** | Interface | ~$7.20/mo | DB credential fetch on Lambda cold start                     |
| **KMS**             | Interface | ~$7.20/mo | Secret decryption, Aurora storage encryption ops             |
| **CloudWatch Logs** | Interface | ~$7.20/mo | All Lambda log output (highest bandwidth)                    |
| **SNS**             | Interface | ~$7.20/mo | Subscription event publishing                                |
| **SSM**             | Interface | ~$7.20/mo | JSON Schema loading on cold start                            |

**Interface endpoint cost**: $0.01/hr × 2 AZs × 730 hrs/mo = ~$14.60/endpoint/mo with 2 AZs, ~$7.30 with 1 AZ. The module deploys in 2 AZs for HA.

#### When to Enable Interface Endpoints

Interface endpoints have a fixed monthly cost. They save money only when NAT data transfer exceeds the endpoint cost:

```text
Breakeven: $7.20/mo ÷ $0.045/GB = ~160 GB/mo per service

If SQS traffic > 160 GB/mo → Interface endpoint saves money
If SQS traffic < 160 GB/mo → NAT is cheaper
```

**Recommendation**:

- **Always enable**: S3 + DynamoDB Gateway endpoints (free)
- **Prod**: Enable all Interface endpoints (high throughput justifies cost)
- **Dev**: Toggle with `enable_vpc_interface_endpoints = false` if cost-sensitive

#### Private DNS — Zero Code Changes

All Interface endpoints enable `private_dns_enabled = true`. This means:

- `sqs.us-east-1.amazonaws.com` resolves to the VPC endpoint's private IP
- No SDK configuration changes, no custom endpoint URLs
- Existing Lambda code works unchanged — the AWS SDK uses standard endpoints

---

### 14. WAF — API Gateway Protection

The `modules/waf` module deploys an AWS WAF v2 Web ACL attached to the HTTP API Gateway stage, providing defense-in-depth against common web attacks, brute-force attempts, and abuse.

#### Rule Evaluation Order

WAF rules are evaluated by priority (lowest number first). This ordering ensures cheapest/broadest filters run before expensive rule group evaluations:

| Priority | Rule | Type | Description |
|----------|------|------|-------------|
| 1 | IP Reputation List | AWS Managed | Blocks IPs known for bot/fraud activity (AWS Threat Intel) |
| 2 | Rate Limit (per-IP) | Rate-based | Blocks IPs exceeding 2000 req/5min (~6.7 req/s) |
| 3 | Common Rule Set | AWS Managed | OWASP Top 10: XSS, path traversal, protocol violations |
| 4 | Known Bad Inputs | AWS Managed | Log4Shell (CVE-2021-44228), SSRF patterns |
| 5 | SQL Injection | AWS Managed | SQLi in headers, query strings, URI paths, body |
| 6 | Geo Restrictions | Custom | Optional country-level blocking (disabled by default) |

#### Count vs Block Mode

For initial deployment, **set `waf_managed_rules_action = "count"`** (the dev default). This logs which requests WOULD be blocked without actually blocking them. After reviewing WAF logs for 1-2 weeks:

1. Check CloudWatch log group `aws-waf-logs-billing-platform-dev` for blocked requests
2. Identify false positives (legitimate requests matched by rules)
3. Add rule exclusions for false positives (e.g., `SizeRestrictions_BODY` for large JSON)
4. Switch to `waf_managed_rules_action = "block"` for enforcement

#### WAF Logging

WAF logs every evaluated request to CloudWatch Logs. The `Authorization` header is **redacted by default** to prevent token leakage in logs. Log group name must start with `aws-waf-logs-` per AWS requirements.

#### WAF Alarm

A CloudWatch alarm fires when blocked requests exceed 100 per 5-minute period, indicating a potential attack or rule misconfiguration. The alarm publishes to the existing observability SNS topic.

#### Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `waf_rate_limit_threshold` | 2000 | Max requests per 5-min per IP |
| `waf_managed_rules_action` | `"count"` (dev) | `"count"` for evaluation, `"block"` for enforcement |
| `waf_blocked_country_codes` | `[]` | ISO country codes to block |
| `waf_enable_logging` | `true` | Enable WAF → CloudWatch logging |

---

### 15. Pre-Token-Generation Lambda — Custom JWT Claims

The `modules/pre-token` module deploys a Cognito pre-token-generation Lambda trigger that enriches JWTs with tenant-specific claims before token issuance. This enables authorization decisions at the API layer without additional database lookups per request.

#### Claims Injected

| Claim | Example Value | Purpose |
|-------|--------------|---------|
| `plan_tier` | `"professional"` | Feature gating, rate limit tiers |
| `tenant_status` | `"active"` | Block suspended tenants at API level |
| `features` | `{"maxUsers":50,...}` | Frontend feature flags (JSON string) |
| `billing_cycle` | `"monthly"` | Display/logic in frontend |

#### How It Works

```text
User Login / Token Refresh
        │
        ▼
  Cognito User Pool
        │
        ▼  (Pre-Token-Generation Trigger)
  Lambda Function
        │
        ├── Extract custom:tenant_id from user attributes
        ├── Query Aurora: tenant + active subscription (LEFT JOIN)
        ├── Resolve effective plan (subscription > tenant > "free")
        ├── Map plan → feature flags (PLAN_FEATURES lookup)
        └── Return claimsOverrideDetails
        │
        ▼
  JWT issued with enriched claims
        │
        ▼
  API Gateway / Lambda handlers read claims from JWT
  (no per-request DB lookup needed for plan/features)
```

#### Plan Feature Matrix

| Feature | Free | Starter | Professional | Enterprise |
|---------|------|---------|--------------|------------|
| Max Users | 3 | 10 | 50 | Unlimited |
| Events/Month | 1,000 | 10,000 | 100,000 | Unlimited |
| Invoice Export | — | ✓ | ✓ | ✓ |
| API Access | — | ✓ | ✓ | ✓ |
| Custom Branding | — | — | ✓ | ✓ |
| Priority Support | — | — | ✓ | ✓ |
| Audit Log | — | — | ✓ | ✓ |
| Webhooks | — | — | ✓ | ✓ |

#### Graceful Fallback

The handler **never blocks authentication**. If the database is unavailable or the tenant is not found, default claims (`plan_tier: "free"`) are returned. A user with limited features is better than a user who cannot log in.

#### Per-Tenant Feature Overrides

Tenant-specific overrides can be stored in `tenants.settings.featureOverrides`. These are merged on top of plan-level features, enabling sales-driven exceptions (e.g., giving a "starter" tenant the `invoiceExport` feature during a trial).

---

## Getting Started

### Prerequisites

- Terraform ≥ 1.5
- AWS CLI configured with appropriate credentials
- Sufficient IAM permissions to create VPC, IAM, S3, DynamoDB resources

### 1. Bootstrap Remote State

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

### 2. Deploy Dev Environment

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars   # customise if needed
terraform init
terraform plan
terraform apply
```

### 3. Add a New Environment (staging/prod)

```bash
cp -r terraform/environments/dev terraform/environments/prod
# Edit backend.tf key path and terraform.tfvars
```

---

## Cost Considerations (Dev)

| Resource             | ~Monthly Cost          |
| -------------------- | ---------------------- |
| NAT Gateway          | $32 + data processing  |
| Elastic IP           | Free (while attached)  |
| DynamoDB (on-demand) | < $1                   |
| S3 (state)           | < $1                   |
| VPC / Subnets / SGs  | Free                   |
| Cognito User Pool    | Free tier: 50k MAU     |
| API Gateway HTTP API | $1/million requests    |
| Lambda (4 functions) | Free tier: 1M req/mo   |
| SNS                  | Free tier: 1M pub/mo   |
| SQS (6 queues)       | Free tier: 1M req/mo   |
| Lambda (3 consumers) | Free tier (shared)     |
| CloudWatch Dashboard | $3/dashboard/month     |
| CloudWatch Alarms    | $0.10/alarm/month      |
| CloudWatch Logs      | $0.50/GB ingested      |
| Custom Metrics (EMF) | Free (via log ingest)  |
| Aurora Serverless v2 | ~$43/mo (0.5 ACU min)  |
| KMS Key (Aurora)     | $1/month + $0.03/10K   |
| Performance Insights | Free (7-day retention) |
| Enhanced Monitoring  | Free tier: 60s         |
| VPC Endpoint (S3)    | Free (Gateway)         |
| VPC Endpoint (DynDB) | Free (Gateway)         |
| VPC Endpoints (×6)   | ~$58/mo (Interface)    |
| WAF Web ACL          | $5/mo + $1/rule group  |
| WAF Requests         | $0.60/million requests |
| WAF Logging          | $0.50/GB (CW Logs)    |
| Pre-Token Lambda     | Free tier (shared)     |

**Prod recommendations**: Deploy NAT GW per AZ (~$64/mo total), add Aurora reader instance(s) for HA failover, set `deletion_protection = true` and `backup_retention_days = 35`. Enable Cognito Advanced Security in ENFORCED mode for adaptive authentication. Switch WAF managed rules to `"block"` after evaluation period. Consider disabling Interface VPC endpoints in dev to save ~$58/mo if NAT costs are lower.

---

## Next Steps

- [x] Add `modules/auth` — Cognito User Pool, App Client, JWT authorizer
- [x] Add `modules/api` — REST routes, Lambda functions, throttling, validation
- [x] Lambda function source code — handlers, shared DB layer, structured logging
- [x] DB migration schema — tenants, subscriptions, invoices, billing_events with RLS
- [x] IAM policies for Secrets Manager and SSM Parameter Store
- [x] Add `modules/events` — SNS fan-out, SQS queues + DLQs, consumer Lambdas
- [x] Event-driven idempotency + partial batch failure reporting
- [x] DB migration for processed_events and audit_logs tables
- [x] Add `modules/observability` — CloudWatch dashboard, alarms, metric filters
- [x] Custom metrics via EMF — invoice_generation_time, subscription_count
- [x] Structured JSON logging with CloudWatch Insights queries
- [x] Add `modules/rds` — Aurora Serverless v2 in private subnets
- [x] Add VPC endpoints for S3, DynamoDB, SQS, Secrets Manager, KMS, Logs, SNS, SSM
- [x] IAM policies for RDS-managed secret + KMS decryption
- [x] Add `modules/waf` — WAF v2 Web ACL with rate limiting, OWASP rules, SQLi, geo-blocking
- [x] Add `modules/pre-token` — Cognito pre-token-generation Lambda for plan tier + feature flags
- [ ] Add RDS Proxy for Lambda connection pooling
- [ ] Add SNS filter policies for event-type-based routing
- [ ] DLQ reprocessing Lambda (replay failed messages)
- [ ] CloudWatch Anomaly Detection for API latency
- [ ] X-Ray distributed tracing across SNS → SQS → Lambda
- [ ] CI/CD pipeline with `terraform plan` on PR, `apply` on merge
