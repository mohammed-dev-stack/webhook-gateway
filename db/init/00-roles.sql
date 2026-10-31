-- Runs once on first container init (docker-entrypoint-initdb.d) as
-- POSTGRES_USER=postgres. Re-running requires "docker compose down -v"
-- to wipe the pgdata volume; without that, roles are not recreated and
-- 002_grants.sql will fail on a missing role.
CREATE ROLE webhook_api        LOGIN PASSWORD 'change_me';
CREATE ROLE webhook_dispatcher LOGIN PASSWORD 'change_me' BYPASSRLS;
CREATE ROLE webhook_admin      LOGIN PASSWORD 'change_me' BYPASSRLS;
CREATE ROLE webhook_auth       LOGIN PASSWORD 'change_me' BYPASSRLS;