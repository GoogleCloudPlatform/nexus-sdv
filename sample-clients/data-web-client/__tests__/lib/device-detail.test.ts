import { getDeviceTimeSeries, DEFAULT_PAGE_SIZE } from '@/lib/device-detail';
import { getTelemetryTable } from '@/lib/bigtable';

jest.mock('@/lib/bigtable');

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
  beforeEach(() => jest.clearAllMocks());

  it('returns empty rows and columns when no data found', async () => {
    const mockTable = { getRows: jest.fn().mockResolvedValue([[]]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDeviceTimeSeries('dev-001', '1h');

    expect(result).toEqual({ deviceId: 'dev-001', columns: [], rows: [], nextCursor: null, hasMore: false });
  });

  it('extracts rows and unions column names across all rows', async () => {
    const mockRows = [
      makeRow('dev-001#2024-01-01T00:00:00.000Z', { dynamic: { temp: Buffer.from('25.0') } }),
      makeRow('dev-001#2024-01-01T00:01:00.000Z', { dynamic: { temp: Buffer.from('26.0'), soc: Buffer.from('85') } }),
    ];
    const mockTable = { getRows: jest.fn().mockResolvedValue([mockRows]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDeviceTimeSeries('dev-001', '1h');

    expect(result.deviceId).toBe('dev-001');
    expect(result.columns).toContain('dynamic:temp');
    expect(result.columns).toContain('dynamic:soc');
    expect(result.rows).toHaveLength(2);
    expect(result.rows[0].values['dynamic:temp']).toBe('25.0');
    expect(result.rows[1].values['dynamic:soc']).toBe('85');
  });

  it('constructs row-key bounds correctly including the # separator', async () => {
    const mockTable = { getRows: jest.fn().mockResolvedValue([[]]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const before = new Date();
    await getDeviceTimeSeries('dev-001', '1h');
    const after = new Date();

    const callArgs = mockTable.getRows.mock.calls[0][0];
    const range = callArgs.ranges[0];

    // start is now an object { value, inclusive }
    const startValue: string = typeof range.start === 'object' ? range.start.value : range.start;
    expect(startValue).toMatch(/^dev-001#/);
    expect(range.end).toMatch(/^dev-001#/);

    const startTs = new Date(startValue.slice('dev-001#'.length));
    const endTs = new Date(range.end.slice('dev-001#'.length));

    expect(before.getTime() - startTs.getTime()).toBeGreaterThanOrEqual(60 * 60 * 1000 - 1000);
    expect(before.getTime() - startTs.getTime()).toBeLessThanOrEqual(60 * 60 * 1000 + 1000);
    expect(endTs.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(endTs.getTime()).toBeLessThanOrEqual(after.getTime());
  });

  it('returns hasMore=false and nextCursor=null when fewer rows than limit', async () => {
    const mockRows = [makeRow('dev-001#2024-01-01T00:00:00.000Z', { dynamic: { temp: Buffer.from('25') } })];
    const mockTable = { getRows: jest.fn().mockResolvedValue([mockRows]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDeviceTimeSeries('dev-001', '1h', undefined, 25);

    expect(result.hasMore).toBe(false);
    expect(result.nextCursor).toBeNull();
    expect(result.rows).toHaveLength(1);
  });

  it('returns hasMore=true and nextCursor when limit+1 rows are returned', async () => {
    const pageSize = 2;
    // Bigtable returns limit+1 = 3 rows
    const mockRows = [
      makeRow('dev-001#2024-01-01T00:00:00.000Z', { dynamic: { temp: Buffer.from('1') } }),
      makeRow('dev-001#2024-01-01T00:01:00.000Z', { dynamic: { temp: Buffer.from('2') } }),
      makeRow('dev-001#2024-01-01T00:02:00.000Z', { dynamic: { temp: Buffer.from('3') } }),
    ];
    const mockTable = { getRows: jest.fn().mockResolvedValue([mockRows]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDeviceTimeSeries('dev-001', '1h', undefined, pageSize);

    expect(result.hasMore).toBe(true);
    expect(result.rows).toHaveLength(pageSize); // extra row stripped
    expect(result.nextCursor).not.toBeNull();
    // nextCursor is base64 of the last row key
    const decoded = Buffer.from(result.nextCursor!, 'base64').toString('utf8');
    expect(decoded).toBe('dev-001#2024-01-01T00:01:00.000Z');
  });

  it('passes decoded cursor as exclusive start key', async () => {
    const mockTable = { getRows: jest.fn().mockResolvedValue([[]]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const rawCursor = 'dev-001#2024-01-01T01:00:00.000Z';
    const encodedCursor = Buffer.from(rawCursor).toString('base64');

    await getDeviceTimeSeries('dev-001', '1h', rawCursor, 25);

    const callArgs = mockTable.getRows.mock.calls[0][0];
    const range = callArgs.ranges[0];
    expect(range.start.value).toBe(rawCursor);
    expect(range.start.inclusive).toBe(false);
  });

  it('requests limit+1 rows from Bigtable', async () => {
    const mockTable = { getRows: jest.fn().mockResolvedValue([[]]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    await getDeviceTimeSeries('dev-001', '1h', undefined, 10);

    const callArgs = mockTable.getRows.mock.calls[0][0];
    expect(callArgs.limit).toBe(11);
  });
});
