import { getTelemetryTable } from './bigtable';
import type { DeviceDetailResponse, TimeRange } from '@/types/telemetry';
import { TIME_RANGE_MS } from '@/types/telemetry';
import { readRowsReversed } from './bigtable-reversed';

export const MAX_PAGE_SIZE = 200;
export const DEFAULT_PAGE_SIZE = 25;

export async function getDeviceTimeSeries(
  deviceId: string,
  range: TimeRange = '1h',
  cursor?: string,
  limit: number = DEFAULT_PAGE_SIZE,
): Promise<DeviceDetailResponse> {
  const table = getTelemetryTable();

  const now = new Date();
  const startTime = new Date(now.getTime() - TIME_RANGE_MS[range]);

  // Range bounds for the BigTable scan.
  //   rangeLow  = oldest boundary of the time window (constant per request).
  //   rangeHigh = either `now` (first page) or the cursor (next pages).
  //
  // The cursor is the row key of the LAST (= oldest) row from the previous
  // page. By moving rangeHigh down to that key for each subsequent page, the
  // reversed scan sweeps progressively further back in time across requests.
  //
  // Even though the iteration is reversed, BigTable requires the bounds in
  // ascending order, so we always pass (rangeLow → rangeHigh) — see the
  // detailed note in `readRowsReversed`.
  const rangeLow  = `${deviceId}#${startTime.toISOString()}`;
  const rangeHigh = cursor ?? `${deviceId}#${now.toISOString()}`;

  // Fetch one extra row to detect whether there's another page after this
  // one without needing a separate count query.
  const fetchLimit = limit + 1;

  const rows = await readRowsReversed(
    table,
    rangeLow,
    rangeHigh,
    !!cursor, // tells the helper this is a cursor-driven page (vs first page)
    fetchLimit,
  );

  const hasMore = rows.length === fetchLimit;
  const pageRows = hasMore ? rows.slice(0, limit) : rows;

  const columnSet = new Set<string>();

  const resultRows = pageRows.map((row) => {
    // Row key format: `{deviceId}#{ISO8601_timestamp}`. Split off the
    // timestamp portion for display.
    const sep = row.id.indexOf('#');
    const timestamp = sep > 0 ? row.id.slice(sep + 1) : row.id;
    const values: Record<string, string> = {};

    // Flatten the (family → qualifier → cells[]) tree into a flat
    // `family:qualifier` → latest-cell-value map for the table view.
    for (const [family, qualifiers] of Object.entries(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ((row as any).data ?? {}) as Record<string, Record<string, Array<{ value: Buffer }>>>
    )) {
      for (const [qualifier, cells] of Object.entries(qualifiers)) {
        if (!cells.length) continue;
        const key = `${family}:${qualifier}`;
        columnSet.add(key);
        // cells[0] is the most-recent cell version — sufficient for the UI.
        values[key] = cells[0].value.toString();
      }
    }

    return { timestamp, values };
  });

  // The cursor we hand back is the last row of this page. Because the scan
  // is reversed, the last row is the OLDEST row currently rendered, and the
  // next page should continue scanning backwards from just before it.
  // We base64-encode it because cursors travel through URL query strings.
  const lastRowKey = pageRows.length > 0 ? pageRows[pageRows.length - 1].id : null;
  const nextCursor = hasMore && lastRowKey
    ? Buffer.from(lastRowKey).toString('base64')
    : null;

  return {
    deviceId,
    columns: Array.from(columnSet),
    rows: resultRows,
    nextCursor,
    hasMore,
  };
}
