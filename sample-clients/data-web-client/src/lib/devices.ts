import { getTelemetryTable } from './bigtable';
import { readRowsReversed } from './bigtable-reversed';
import type { DeviceRow } from '@/types/telemetry';

export async function getDevices(allowedVehicleIds?: string[]): Promise<DeviceRow[]> {
  const table = getTelemetryTable();

  let deviceIds: Set<string>;

  if (allowedVehicleIds !== undefined) {
    // ACL path: skip the key scan entirely, use the caller-supplied list.
    deviceIds = new Set(allowedVehicleIds);
  } else {
    // Pass 1: key-only scan to discover unique device IDs.
    // StripValueTransformer filter reads keys and discards all cell values.
    deviceIds = await new Promise<Set<string>>((resolve, reject) => {
      const ids = new Set<string>();
      const stream = table.createReadStream({ filter: [{ value: { strip: true } }] });
      stream.on('data', (row: { id: string }) => {
        const sep = row.id.indexOf('#');
        if (sep > 0) ids.add(row.id.slice(0, sep));
      });
      stream.on('error', reject);
      stream.on('end', () => resolve(ids));
    });
  }

  // Pass 2: the newest row of each device.
  const devices: DeviceRow[] = [];

  for (const deviceId of deviceIds) {
    // readRowsReversed, not table.getRows({reversed: true}): the high-level API
    // silently drops `reversed`, which is what made this function return each
    // device's OLDEST row. The helper next door builds the raw gRPC request and
    // is what the device detail page has used all along.
    const rows = await readRowsReversed(table, `${deviceId}#`, `${deviceId}$`, false, 1);

    if (!rows?.length) continue;

    const row = rows[0];
    const sep = row.id.indexOf('#');
    const lastSeen = sep > 0 ? row.id.slice(sep + 1) : '';
    const columns: Record<string, string> = {};

    for (const [family, qualifiers] of Object.entries(
      (row.data ?? {}) as Record<string, Record<string, Array<{ value: Buffer }>>>
    )) {
      for (const [qualifier, cells] of Object.entries(qualifiers)) {
        if (!cells.length) continue;
        columns[`${family}:${qualifier}`] = cells[0].value.toString();
      }
    }

    devices.push({ deviceId, lastSeen, columns });
  }

  return devices;
}
