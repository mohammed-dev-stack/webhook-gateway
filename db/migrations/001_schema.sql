-- Tables first, grants in 002 (C4). Runs as postgres.

CREATE TABLE tenants (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  disabled   boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE api_keys (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants(id),
  prefix       text NOT NULL UNIQUE,
  key_hash     bytea NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  expires_at   timestamptz,
  last_used_at timestamptz
);
CREATE INDEX api_keys_tenant_idx ON api_keys (tenant_id);

CREATE TABLE endpoints (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  url             text NOT NULL,
  description     text,
  enabled         boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  disabled_at     timestamptz,
  disabled_reason text,
  UNIQUE (id, tenant_id)
);
CREATE INDEX endpoints_tenant_idx ON endpoints (tenant_id);

CREATE TABLE endpoint_secrets (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  endpoint_id       uuid NOT NULL,
  tenant_id         uuid NOT NULL,
  secret_prefix     text NOT NULL,
  secret_ciphertext bytea NOT NULL,
  is_primary        boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz,
  revoked_at        timestamptz,
  FOREIGN KEY (endpoint_id, tenant_id) REFERENCES endpoints(id, tenant_id)
);
CREATE INDEX endpoint_secrets_active_idx ON endpoint_secrets (endpoint_id)
  WHERE revoked_at IS NULL;

CREATE TABLE subscriptions (
  endpoint_id uuid NOT NULL,
  tenant_id   uuid NOT NULL,
  event_type  text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, event_type),
  FOREIGN KEY (endpoint_id, tenant_id) REFERENCES endpoints(id, tenant_id)
);
CREATE INDEX subscriptions_tenant_event_idx ON subscriptions (tenant_id, event_type);

CREATE TABLE events (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  event_type      text NOT NULL,
  idempotency_key text,
  payload_hash    bytea NOT NULL,
  payload_bytes   bytea NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id)
);
CREATE UNIQUE INDEX events_idem_uniq ON events (tenant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX events_tenant_created_idx ON events (tenant_id, created_at);

CREATE TABLE deliveries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        uuid NOT NULL,
  endpoint_id     uuid NOT NULL,
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'processing', 'succeeded', 'dlq', 'paused')),
  attempts        integer NOT NULL DEFAULT 0,
  total_attempts  integer NOT NULL DEFAULT 0,
  max_attempts    integer NOT NULL,
  reclaim_count   integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_until    timestamptz,
  lease_token     uuid,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (event_id, tenant_id) REFERENCES events(id, tenant_id),
  FOREIGN KEY (endpoint_id, tenant_id) REFERENCES endpoints(id, tenant_id),
  UNIQUE (event_id, endpoint_id)
) WITH (fillfactor = 80);

CREATE INDEX deliveries_claim_pending_idx ON deliveries (next_attempt_at)
  WHERE status = 'pending';
CREATE INDEX deliveries_claim_expired_idx ON deliveries (locked_until)
  WHERE status = 'processing';
CREATE INDEX deliveries_event_idx ON deliveries (event_id);
CREATE INDEX deliveries_endpoint_status_idx ON deliveries (endpoint_id, status);
CREATE INDEX deliveries_tenant_status_idx ON deliveries (tenant_id, status);
CREATE INDEX deliveries_paused_idx ON deliveries (endpoint_id) WHERE status = 'paused';

CREATE TABLE delivery_attempts (
  id              bigserial PRIMARY KEY,
  delivery_id     uuid NOT NULL REFERENCES deliveries(id),
  attempt_number  integer NOT NULL,
  lease_token     uuid NOT NULL,
  started_at      timestamptz NOT NULL,
  finished_at     timestamptz NOT NULL DEFAULT now(),
  outcome         text NOT NULL CHECK (outcome IN ('success', 'retryable', 'permanent')),
  http_status     integer,
  error_class     text,
  response_snippet text,
  duration_ms     integer,
  UNIQUE (delivery_id, attempt_number)
);
CREATE INDEX delivery_attempts_delivery_idx ON delivery_attempts (delivery_id);

ALTER TABLE tenants          ENABLE ROW LEVEL SECURITY; ALTER TABLE tenants          FORCE ROW LEVEL SECURITY;
ALTER TABLE endpoints        ENABLE ROW LEVEL SECURITY; ALTER TABLE endpoints        FORCE ROW LEVEL SECURITY;
ALTER TABLE endpoint_secrets ENABLE ROW LEVEL SECURITY; ALTER TABLE endpoint_secrets FORCE ROW LEVEL SECURITY;
ALTER TABLE subscriptions    ENABLE ROW LEVEL SECURITY; ALTER TABLE subscriptions    FORCE ROW LEVEL SECURITY;
ALTER TABLE events           ENABLE ROW LEVEL SECURITY; ALTER TABLE events           FORCE ROW LEVEL SECURITY;
ALTER TABLE deliveries       ENABLE ROW LEVEL SECURITY; ALTER TABLE deliveries       FORCE ROW LEVEL SECURITY;

CREATE POLICY tenants_iso ON tenants
  USING (id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY endpoints_iso ON endpoints
  USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY endpoint_secrets_iso ON endpoint_secrets
  USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY subscriptions_iso ON subscriptions
  USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY events_iso ON events
  USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY deliveries_iso ON deliveries
  USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE FUNCTION auth_resolve(p_prefix text)
RETURNS TABLE (key_id uuid, tenant_id uuid, key_hash bytea,
               revoked_at timestamptz, expires_at timestamptz, tenant_disabled boolean)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT k.id, k.tenant_id, k.key_hash, k.revoked_at, k.expires_at, t.disabled
  FROM api_keys k JOIN tenants t ON t.id = k.tenant_id
  WHERE k.prefix = p_prefix
$$;
ALTER FUNCTION auth_resolve(text) OWNER TO webhook_auth;