-- C4: grants after all tables and the function exist.

GRANT USAGE ON SCHEMA public TO webhook_api, webhook_dispatcher, webhook_admin, webhook_auth;

GRANT SELECT ON api_keys, tenants TO webhook_auth;

GRANT SELECT, INSERT, UPDATE ON endpoints         TO webhook_api;
GRANT SELECT, INSERT, UPDATE ON endpoint_secrets  TO webhook_api;
GRANT SELECT, INSERT, UPDATE ON subscriptions     TO webhook_api;
GRANT SELECT, INSERT         ON events            TO webhook_api;
GRANT SELECT, INSERT         ON deliveries        TO webhook_api;
GRANT SELECT                 ON tenants           TO webhook_api;
GRANT EXECUTE ON FUNCTION auth_resolve(text) TO webhook_api;

GRANT SELECT, UPDATE ON deliveries        TO webhook_dispatcher;
GRANT SELECT          ON events, endpoints, endpoint_secrets, tenants TO webhook_dispatcher;
GRANT SELECT, INSERT  ON delivery_attempts TO webhook_dispatcher;
GRANT USAGE, SELECT   ON SEQUENCE delivery_attempts_id_seq TO webhook_dispatcher;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO webhook_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO webhook_admin;