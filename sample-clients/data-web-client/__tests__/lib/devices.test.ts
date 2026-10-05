import { Readable } from 'stream';
import { getDevices } from '@/lib/devices';
import { getTelemetryTable } from '@/lib/bigtable';
import { readRowsReversed } from '@/lib/bigtable-reversed';

jest.mock('@/lib/bigtable');
// Same seam as device-detail.test.ts: the reversed read goes through BigTable's
// raw gRPC path, so it is mocked here rather than reproducing the SDK's chunk
// format.
jest.mock('@/lib/bigtable-reversed', () => ({ readRowsReversed: jest.fn() }));

function makeStream(rows: { id: string }[]) {
  return Readable.from(rows, { objectMode: true });
}

const reversed = readRowsReversed as jest.Mock;

describe('getDevices', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns empty array when table is empty', async () => {
    const mockTable = { createReadStream: jest.fn().mockReturnValue(makeStream([])) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDevices();

    expect(result).toEqual([]);
    expect(reversed).not.toHaveBeenCalled();
  });

  it('returns one entry per unique device with latest row data', async () => {
    const keyRows = [
      { id: 'dev-001#2024-01-01T00:00:00.000Z' },
      { id: 'dev-001#2024-01-01T00:01:00.000Z' },
      { id: 'dev-002#2024-01-01T00:00:30.000Z' },
    ];
    const latestDev1 = {
      id: 'dev-001#2024-01-01T00:01:00.000Z',
      data: { dynamic: { 'battery.temp': [{ value: Buffer.from('25.0') }] } },
    };
    const latestDev2 = {
      id: 'dev-002#2024-01-01T00:00:30.000Z',
      data: { static: { index: [{ value: Buffer.from('7') }] } },
    };

    (getTelemetryTable as jest.Mock).mockReturnValue({
      createReadStream: jest.fn().mockReturnValue(makeStream(keyRows)),
    });
    reversed.mockResolvedValueOnce([latestDev1]).mockResolvedValueOnce([latestDev2]);

    const result = await getDevices();

    expect(result).toHaveLength(2);
    const dev1 = result.find((d) => d.deviceId === 'dev-001')!;
    expect(dev1.lastSeen).toBe('2024-01-01T00:01:00.000Z');
    expect(dev1.columns).toEqual({ 'dynamic:battery.temp': '25.0' });
    expect(result.find((d) => d.deviceId === 'dev-002')!.columns).toEqual({ 'static:index': '7' });
  });

  // The regression this guards against: the per-device read used
  // `table.getRows({limit: 1, reversed: true})`. Table.getRows does not support
  // `reversed` and dropped it silently, so the scan ran ascending and returned
  // each device's OLDEST row — displayed in the list as "last seen".
  //
  // The guarantee now lives in readRowsReversed, which builds the raw gRPC
  // request. What this file has to assert is that getDevices goes through it,
  // over the device's whole key range, for exactly one row.
  it('reads the newest row through the reversed path, not an ascending scan', async () => {
    (getTelemetryTable as jest.Mock).mockReturnValue({
      createReadStream: jest
        .fn()
        .mockReturnValue(makeStream([{ id: 'dev-001#2024-01-01T00:00:00.000Z' }])),
    });
    reversed.mockResolvedValue([
      {
        id: 'dev-001#2024-01-02T00:00:00.000Z',
        data: { dynamic: { speed: [{ value: Buffer.from('80') }] } },
      },
    ]);

    const result = await getDevices();

    expect(reversed).toHaveBeenCalledTimes(1);
    const [, rangeLow, rangeHigh, , limit] = reversed.mock.calls[0];
    expect(rangeLow).toBe('dev-001#');
    expect(rangeHigh).toBe('dev-001$');
    expect(limit).toBe(1);
    // Whatever the reversed read returns is what "last seen" reports.
    expect(result[0].lastSeen).toBe('2024-01-02T00:00:00.000Z');
  });

  it('skips the key scan and reads only allowed vehicles when allowedVehicleIds is given', async () => {
    const mockTable = { createReadStream: jest.fn() };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);
    reversed.mockResolvedValueOnce([
      {
        id: 'dev-001#2024-01-01T00:00:00.000Z',
        data: { dynamic: { temp: [{ value: Buffer.from('20') }] } },
      },
    ]);

    const result = await getDevices(['dev-001']);

    expect(mockTable.createReadStream).not.toHaveBeenCalled();
    expect(reversed).toHaveBeenCalledTimes(1);
    expect(result).toHaveLength(1);
    expect(result[0].deviceId).toBe('dev-001');
    expect(result[0].columns).toEqual({ 'dynamic:temp': '20' });
  });

  it('returns empty array without hitting BigTable when allowedVehicleIds is empty', async () => {
    const mockTable = { createReadStream: jest.fn() };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDevices([]);

    expect(mockTable.createReadStream).not.toHaveBeenCalled();
    expect(reversed).not.toHaveBeenCalled();
    expect(result).toEqual([]);
  });
});
