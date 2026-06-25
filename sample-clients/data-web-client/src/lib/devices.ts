import { getTelemetryTable } from './bigtable';
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

  // Pass 2: reversed scan per device — first result = latest row.
  // Range [{deviceId}#, {deviceId}$) covers all timestamps for that device.
  // '$' (ASCII 36) > '#' (ASCII 35), so the range is tight and won't bleed into other devices.
  const devices: DeviceRow[] = [];

  for (const deviceId of deviceIds) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const getRowsResult = await (table.getRows as any)({
      ranges: [{ start: `${deviceId}#`, end: `${deviceId}$` }],
      limit: 1,
      reversed: true,
    }) as [import('@google-cloud/bigtable').Row[], object, object];
    const rows = getRowsResult[0];

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
