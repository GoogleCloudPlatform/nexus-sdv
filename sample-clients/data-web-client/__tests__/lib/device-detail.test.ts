import { getDeviceTimeSeries } from '@/lib/device-detail';
import { getTelemetryTable } from '@/lib/bigtable';

jest.mock('@/lib/bigtable');

describe('getDeviceTimeSeries', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns empty rows and columns when no data found', async () => {
    const mockTable = { getRows: jest.fn().mockResolvedValue([[]]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDeviceTimeSeries('dev-001', '1h');

    expect(result).toEqual({ deviceId: 'dev-001', columns: [], rows: [] });
  });

  it('extracts rows and unions column names across all rows', async () => {
    const mockRows = [
      {
        id: 'dev-001#2024-01-01T00:00:00.000Z',
        data: { dynamic: { temp: [{ value: Buffer.from('25.0') }] } },
      },
      {
        id: 'dev-001#2024-01-01T00:01:00.000Z',
        data: {
          dynamic: {
            temp: [{ value: Buffer.from('26.0') }],
            soc: [{ value: Buffer.from('85') }],
          },
        },
      },
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

    expect(range.start).toMatch(/^dev-001#/);
    expect(range.end).toMatch(/^dev-001#/);

    const startTs = new Date(range.start.slice('dev-001#'.length));
    const endTs = new Date(range.end.slice('dev-001#'.length));

    // start should be ~1h before now
    expect(before.getTime() - startTs.getTime()).toBeGreaterThanOrEqual(60 * 60 * 1000 - 1000);
    expect(before.getTime() - startTs.getTime()).toBeLessThanOrEqual(60 * 60 * 1000 + 1000);

    // end should be approximately now
    expect(endTs.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(endTs.getTime()).toBeLessThanOrEqual(after.getTime());
  });
});
