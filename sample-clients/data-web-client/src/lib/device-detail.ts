import { getTelemetryTable } from './bigtable';
import type { DeviceDetailResponse, TimeRange } from '@/types/telemetry';
import { TIME_RANGE_MS } from '@/types/telemetry';

export async function getDeviceTimeSeries(
  deviceId: string,
  range: TimeRange = '1h',
): Promise<DeviceDetailResponse> {
  const table = getTelemetryTable();

  const now = new Date();
  const startTime = new Date(now.getTime() - TIME_RANGE_MS[range]);

  // Row key bounds include the '#' separator so we don't bleed into adjacent device keys
  const startKey = `${deviceId}#${startTime.toISOString()}`;
  const endKey = `${deviceId}#${now.toISOString()}`;

  const [rows] = await table.getRows({
    ranges: [{ start: startKey, end: endKey }],
  });

  const columnSet = new Set<string>();

  const resultRows = (rows ?? []).map((row) => {
    const sep = row.id.indexOf('#');
    const timestamp = sep > 0 ? row.id.slice(sep + 1) : row.id;
    const values: Record<string, string> = {};

    for (const [family, qualifiers] of Object.entries(
      (row.data ?? {}) as Record<string, Record<string, Array<{ value: Buffer }>>>
    )) {
      for (const [qualifier, cells] of Object.entries(qualifiers)) {
        if (!cells.length) continue;
        const key = `${family}:${qualifier}`;
        columnSet.add(key);
        values[key] = cells[0].value.toString();
      }
    }

    return { timestamp, values };
  });

  return { deviceId, columns: Array.from(columnSet), rows: resultRows };
}
