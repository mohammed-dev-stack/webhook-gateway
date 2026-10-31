import { Client } from 'pg';
import { migrate } from '../../src/db/migrate';

const HOST = '127.0.0.1';
const PORT = Number(process.env.PGPORT ?? 5433);

const PASSWORDS: Record<string, string> = {
  postgres: process.env.PGPASSWORD ?? 'postgres',
  webhook_api: 'change_me',
  webhook_dispatcher: 'change_me',
  webhook_admin: 'change_me',
  webhook_auth: 'change_me',
};

export type Role =
  | 'postgres'
  | 'webhook_api'
  | 'webhook_dispatcher'
  | 'webhook_admin'
  | 'webhook_auth';

export const ADMIN_CONN = {
  host: HOST,
  port: PORT,
  user: 'postgres',
  password: PASSWORDS.postgres,
  database: 'postgres',
};

const registeredClients: Client[] = [];

function track(c: Client): Client {
  registeredClients.push(c);
  return c;
}

export async function createTestDatabase(): Promise<{ name: string; pool: Client }> {
  const admin = new Client(ADMIN_CONN);
  await admin.connect();
  const name = `whtest_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  try {
    await admin.query(`CREATE DATABASE ${name}`);
  } finally {
    await admin.end();
  }
  await migrate(name);
  const pool = new Client({
    host: HOST, port: PORT, user: 'postgres',
    password: PASSWORDS.postgres, database: name,
  });
  await pool.connect();
  track(pool);
  return { name, pool };
}

export async function connectAs(dbName: string, role: Role): Promise<Client> {
  const c = new Client({
    host: HOST, port: PORT, user: role,
    password: PASSWORDS[role], database: dbName,
  });
  await c.connect();
  track(c);
  return c;
}

export async function closeAllClients(): Promise<void> {
  while (registeredClients.length > 0) {
    const c = registeredClients.pop() as Client;
    try { await c.end(); } catch { /* already ended */ }
  }
}

export async function dropTestDatabase(name: string): Promise<void> {
  await closeAllClients();
  const admin = new Client(ADMIN_CONN);
  await admin.connect();
  try {
    await admin.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);
  } finally {
    await admin.end();
  }
}