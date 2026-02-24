###############################################################################
# Auth Module — Amazon Cognito Multi-Tenant Authentication
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#
#   • Single User Pool, multi-tenant via custom `tenant_id` claim.
#     One pool per environment avoids cross-env token leakage while keeping
#     operational overhead low.  Tenant isolation is enforced at the JWT claim
#     level, NOT by creating a pool per tenant (which doesn't scale beyond
#     ~100 tenants due to Cognito quotas).
#
#   • App client created WITHOUT a secret — required for public clients
#     (SPAs, mobile apps) that use the Authorization Code + PKCE flow.
#     Server-side backends can use the same client or a separate confidential
#     one added later.
#
#   • Custom attribute `tenant_id` is immutable once set (mutable = false).
#     This prevents users from switching tenants by modifying their own
#     profile.  Only admins with Cognito admin API access can set it at
#     sign-up or migration time.
#
#   • Cognito Groups `ADMIN` and `USER` map to role-based authorization.
#     The group name appears in the `cognito:groups` claim of the ID/access
#     token, which Lambda authorizers or API GW JWT authorizers can inspect.
#
#   • Password policy follows NIST 800-63B: min 12 chars, no forced special
#     characters (encourages passphrases over "P@ssw0rd!" patterns), temp
#     password valid for 7 days.
#
#   • Schema includes standard email attribute + custom tenant_id.
#     email is the sign-in alias (username_attributes = ["email"]).
#
#   • Pre-token-generation Lambda trigger hook is exposed as an optional
#     variable.  When set, it can inject additional claims (tenant plan tier,
#     feature flags) into the JWT — useful for fine-grained authorization.
#
#   • API Gateway Authorizer is created as a JWT authorizer (HTTP API style)
#     that validates tokens against the Cognito User Pool issuer and audience.
#     This eliminates the need for a custom Lambda authorizer in most cases.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────── #
# Cognito User Pool
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cognito_user_pool" "main" {
  name = "${var.project}-${var.environment}-user-pool"

  # ---------- Sign-in configuration --------------------------------------- #
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Users cannot sign themselves up — admins or the app backend creates them
  # and assigns the tenant_id.  Prevents orphan users without a tenant.
  admin_create_user_config {
    allow_admin_create_user_only = var.allow_admin_create_user_only
  }

  # ---------- Password policy (NIST 800-63B aligned) ---------------------- #
  password_policy {
    minimum_length                   = var.password_minimum_length
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # ---------- Custom attributes ------------------------------------------- #
  schema {
    name                = "tenant_id"
    attribute_data_type = "String"
    mutable             = false # Immutable — prevents tenant-hopping
    required            = false # Cannot be required for custom attrs in Cognito

    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  # ---------- Email configuration ----------------------------------------- #
  # Use Cognito default email for dev; switch to SES for prod (higher limits).
  email_configuration {
    email_sending_account = var.ses_email_identity != "" ? "DEVELOPER" : "COGNITO_DEFAULT"
    source_arn            = var.ses_email_identity != "" ? var.ses_email_identity : null
  }

  # ---------- Account recovery -------------------------------------------- #
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # ---------- Advanced security ------------------------------------------- #
  user_pool_add_ons {
    advanced_security_mode = var.advanced_security_mode
  }

  # ---------- Pre-token generation trigger (optional) --------------------- #
  dynamic "lambda_config" {
    for_each = var.pre_token_generation_lambda_arn != "" ? [1] : []
    content {
      pre_token_generation = var.pre_token_generation_lambda_arn
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-user-pool"
  })
}

# ──────────────────────────────────────────────────────────────────────────── #
# App Client — No Secret (public client for SPA / mobile)
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cognito_user_pool_client" "app" {
  name         = "${var.project}-${var.environment}-app-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # No client secret — required for public clients (PKCE flow)
  generate_secret = false

  # Explicit auth flows
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",          # Secure Remote Password (recommended)
    "ALLOW_REFRESH_TOKEN_AUTH",     # Token refresh
    "ALLOW_USER_PASSWORD_AUTH",     # Direct username/password (for testing / migration)
  ]

  # Supported identity providers
  supported_identity_providers = ["COGNITO"]

  # Token validity
  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.id_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # OAuth configuration — callback URLs set when frontend is deployed
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = var.callback_urls
  logout_urls                          = var.logout_urls

  # Read/write attributes
  read_attributes  = ["email", "email_verified", "custom:tenant_id"]
  write_attributes = ["email"]
  # Note: custom:tenant_id is NOT in write_attributes — only admins can set it
  # via the Admin API, enforcing tenant assignment control.

  prevent_user_existence_errors = "ENABLED"
}

# ──────────────────────────────────────────────────────────────────────────── #
# User Pool Domain — Required for hosted UI / OAuth endpoints
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# ──────────────────────────────────────────────────────────────────────────── #
# Cognito Groups — Role-Based Access Control
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cognito_user_group" "admin" {
  name         = "ADMIN"
  description  = "Tenant administrators — full access to tenant resources"
  user_pool_id = aws_cognito_user_pool.main.id
  precedence   = 1
}

resource "aws_cognito_user_group" "user" {
  name         = "USER"
  description  = "Standard tenant users — read/limited write access"
  user_pool_id = aws_cognito_user_pool.main.id
  precedence   = 10
}

# ──────────────────────────────────────────────────────────────────────────── #
# Resource Server — Custom OAuth Scopes (for machine-to-machine later)
# ──────────────────────────────────────────────────────────────────────────── #

resource "aws_cognito_resource_server" "api" {
  identifier   = "https://api.${var.project}.${var.environment}"
  name         = "${var.project}-${var.environment}-api"
  user_pool_id = aws_cognito_user_pool.main.id

  scope {
    scope_name        = "billing.read"
    scope_description = "Read billing data"
  }

  scope {
    scope_name        = "billing.write"
    scope_description = "Create/modify billing records"
  }
}

# ──────────────────────────────────────────────────────────────────────────── #
# API Gateway — JWT Authorizer (HTTP API v2)
# ──────────────────────────────────────────────────────────────────────────── #
# This authorizer validates JWTs issued by Cognito.  API Gateway verifies:
#   1. Token signature against the JWKS endpoint (/.well-known/jwks.json)
#   2. Token expiration (exp claim)
#   3. Issuer matches the User Pool (iss claim)
#   4. Audience matches the App Client ID (aud / client_id claim)
#
# After validation, the decoded claims (including custom:tenant_id and
# cognito:groups) are available in the Lambda integration event under
# $request.requestContext.authorizer.jwt.claims.

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-${var.environment}-api"
  protocol_type = "HTTP"
  description   = "HTTP API for ${var.project} (${var.environment})"

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type", "X-Tenant-Id"]
    max_age       = 3600
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-api"
  })
}

resource "aws_apigatewayv2_authorizer" "cognito_jwt" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    audience = [aws_cognito_user_pool_client.app.id]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access_logs.arn

    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      tenantId       = "$context.authorizer.claims.custom:tenant_id"
      userGroups     = "$context.authorizer.claims.cognito:groups"
    })
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-api-default-stage"
  })
}

resource "aws_cloudwatch_log_group" "api_access_logs" {
  name              = "/aws/apigateway/${var.project}-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-api-access-logs"
  })
}
