import { getDeviceTimeSeries } from '@/lib/device-detail';
import { getTelemetryTable } from '@/lib/bigtable';
import { readRowsReversed } from '@/lib/bigtable-reversed';

jest.mock('@/lib/bigtable');
// The reversed scan goes through BigTable's raw gRPC stream (see
// bigtable-reversed.ts). Mocking it at that seam keeps these tests about
// getDeviceTimeSeries' own logic — scan bounds, paging and row shaping — rather
// than about the SDK's internal chunk format.
jest.mock('@/lib/bigtable-reversed', () => ({ readRowsReversed: jest.fn() }));

const mockReadRowsReversed = readRowsReversed as jest.Mock;
const mockTable = { name: 'telemetry' };

function makeRow(id: string, data: Record<string, Record<string, Buffer>>) {
  return {
    id,
    data: Object.fromEntries(
      Object.entries(data).map(([family, quals]) => [
        family,
        Object.fromEntries(
          Object.entries(quals).map(([q, buf]) => [q, [{ value: buf }]])
        ),
      ])
    ),
  };
}

describe('getDeviceTimeSeries', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);
  });

  it('returns empty rows and columns when no data found', async () => {
    mockReadRowsReversed.mockResolvedValue([]);

    const result = await getDeviceTimeSeries('dev-001', '1h');

    expect(result).toEqual({ deviceId: 'dev-001', columns: [], rows: [], nextCursor: null, hasMore: false });
  });

  it('extracts rows and unions column names across all rows', async () => {
    mockReadRowsReversed.mockResolvedValue([
      makeRow('dev-001#2024-01-01T00:00:00.000Z', { dynamic: { temp: Buffer.from('25.0') } }),
      makeRow('dev-001#2024-01-01T00:01:00.000Z', { dynamic: { temp: Buffer.from('26.0'), soc: Buffer.from('85') } }),
    ]);

    const result = await getDeviceTimeSeries('dev-001', '1h');

    expect(result.deviceId).toBe('dev-001');
    expect(result.columns).toContain('dynamic:temp');
    expect(result.columns).toContain('dynamic:soc');
    expect(result.rows).toHaveLength(2);
    expect(result.rows[0].values['dynamic:temp']).toBe('25.0');
    expect(result.rows[1].values['dynamic:soc']).toBe('85');
  });

  it('scans the requested window, from one hour ago up to now', async () => {
    mockReadRowsReversed.mockResolvedValue([]);

    const before = new Date();
    await getDeviceTimeSeries('dev-001', '1h');
    const after = new Date();

    const [table, rangeLow, rangeHigh, cursorExclusive] = mockReadRowsReversed.mock.calls[0];
    expect(table).toBe(mockTable);
    expect(rangeLow).toMatch(/^dev-001#/);
    expect(rangeHigh).toMatch(/^dev-001#/);
    expect(cursorExclusive).toBe(false);

    const lowTs = new Date(rangeLow.slice('dev-001#'.length));
    const highTs = new Date(rangeHigh.slice('dev-001#'.length));
    expect(before.getTime() - lowTs.getTime()).toBeGreaterThanOrEqual(60 * 60 * 1000 - 1000);
    expect(before.getTime() - lowTs.getTime()).toBeLessThanOrEqual(60 * 60 * 1000 + 1000);
    expect(highTs.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(highTs.getTime()).toBeLessThanOrEqual(after.getTime());
  });

  it('returns hasMore=false and nextCursor=null when fewer rows than limit', async () => {
    mockReadRowsReversed.mockResolvedValue([
      makeRow('dev-001#2024-01-01T00:00:00.000Z', { dynamic: { temp: Buffer.from('25') } }),
    ]);

    const result = await getDeviceTimeSeries('dev-001', '1h', undefined, 25);

    expect(result.hasMore).toBe(false);
    expect(result.nextCursor).toBeNull();
    expect(result.rows).toHaveLength(1);
  });

  it('returns hasMore=true and a base64 nextCursor when limit+1 rows come back', async () => {
    const pageSize = 2;
    mockReadRowsReversed.mockResolvedValue([
      makeRow('dev-001#2024-01-01T00:00:00.000Z', { dynamic: { temp: Buffer.from('1') } }),
      makeRow('dev-001#2024-01-01T00:01:00.000Z', { dynamic: { temp: Buffer.from('2') } }),
      makeRow('dev-001#2024-01-01T00:02:00.000Z', { dynamic: { temp: Buffer.from('3') } }),
    ]);

    const result = await getDeviceTimeSeries('dev-001', '1h', undefined, pageSize);

    expect(result.hasMore).toBe(true);
    expect(result.rows).toHaveLength(pageSize); // extra row stripped
    const decoded = Buffer.from(result.nextCursor!, 'base64').toString('utf8');
    expect(decoded).toBe('dev-001#2024-01-01T00:01:00.000Z');
  });

  it('uses the cursor as the exclusive upper bound of the reversed scan', async () => {
    mockReadRowsReversed.mockResolvedValue([]);
    const rawCursor = 'dev-001#2024-01-01T01:00:00.000Z';

    await getDeviceTimeSeries('dev-001', '1h', rawCursor, 25);

    const [, , rangeHigh, cursorExclusive] = mockReadRowsReversed.mock.calls[0];
    expect(rangeHigh).toBe(rawCursor);
    expect(cursorExclusive).toBe(true);
  });

  it('requests limit+1 rows so it can tell whether another page exists', async () => {
    mockReadRowsReversed.mockResolvedValue([]);

    await getDeviceTimeSeries('dev-001', '1h', undefined, 10);

    expect(mockReadRowsReversed.mock.calls[0][4]).toBe(11);
  });
});
