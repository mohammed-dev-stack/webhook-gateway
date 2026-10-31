import { Client } from 'pg';

/** C3: SET LOCAL cannot take bind parameters. Use set_config with is_local=true. */
export async function withTenant<T>(
  c: Client, tenantId: string, fn: () => Promise<T>,
): Promise<T> {
  await c.query('BEGIN');
  try {
    await c.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
    const out = await fn();
    await c.query('COMMIT');
    return out;
  } catch (err) {
    await c.query('ROLLBACK');
    throw err;
  }
}