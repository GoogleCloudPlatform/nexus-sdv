import { Pool } from 'pg';

let pool: Pool | null = null;

function getPool(): Pool {
  if (!pool) {
    pool = new Pool({ connectionString: process.env.DATABASE_URL });
  }
  return pool;
}

export async function getAllowedVehicleIds(groups: string[]): Promise<string[]> {
  if (!groups.length) return [];
  const result = await getPool().query<{ vehicle_id: string }>(
    'SELECT DISTINCT vehicle_id FROM vehicle_groups WHERE group_name = ANY($1)',
    [groups],
  );
  return result.rows.map((r) => r.vehicle_id);
}
