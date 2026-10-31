import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';

// قراءة ملف الـ .env يدوياً وبأمان إن وجد في جذر المشروع
const envPath = join(__dirname, '../../.env');
if (existsSync(envPath)) {
  const envConfig = readFileSync(envPath, 'utf8');
  for (const line of envConfig.split('\n')) {
    const match = line.match(/^([^=]+)=(.*)$/);
    if (match) {
      const key = match[1].trim();
      const value = match[2].trim().replace(/^["'](.*)["']$/, '$1');
      if (!process.env[key]) {
        process.env[key] = value;
      }
    }
  }
}

const MIGRATIONS_DIR = join(__dirname, '../../db/migrations');
const connectionString = process.env.DATABASE_URL || 'postgres://postgres:postgres@127.0.0.1:5432/webhooks';

export async function migrate(dbName?: string): Promise<void> {
  const client = new Client({
    connectionString: dbName ? undefined : connectionString,
    host: process.env.PGHOST || '127.0.0.1',
    port: Number(process.env.PGPORT || 5432),
    user: process.env.PGUSER || 'postgres',
    password: process.env.PGPASSWORD || 'postgres',
    database: dbName || process.env.PGDATABASE || 'webhooks',
  });

  await client.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS _migrations (
        name text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`);
    
    const applied = new Set(
      (await client.query<{ name: string }>('SELECT name FROM _migrations')).rows.map(r => r.name),
    );

    const files = readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort();
    
    for (const file of files) {
      if (applied.has(file)) continue;
      const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO _migrations (name) VALUES ($1)', [file]);
        await client.query('COMMIT');
        console.log(`[Migration] Successfully applied: ${file}`);
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`migration ${file} failed: ${(err as Error).message}`);
      }
    }
  } finally {
    await client.end();
  }
}

if (require.main === module) {
  migrate().catch(err => {
    console.error('Migration failed critically:', err);
    process.exit(1);
  });
}