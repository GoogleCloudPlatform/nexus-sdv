import { Readable } from 'stream';
import { getDevices } from '@/lib/devices';
import { getTelemetryTable } from '@/lib/bigtable';

jest.mock('@/lib/bigtable');

function makeStream(rows: { id: string }[]) {
  return Readable.from(rows, { objectMode: true });
}

describe('getDevices', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns empty array when table is empty', async () => {
    const mockTable = {
      createReadStream: jest.fn().mockReturnValue(makeStream([])),
      getRows: jest.fn(),
    };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDevices();

    expect(result).toEqual([]);
    expect(mockTable.getRows).not.toHaveBeenCalled();
  });

  it('returns one entry per unique device with latest row data', async () => {
    const keyRows = [
      { id: 'dev-001#2024-01-01T00:00:00.000Z' },
      { id: 'dev-001#2024-01-01T00:01:00.000Z' },
      { id: 'dev-002#2024-01-01T00:00:30.000Z' },
    ];

    const latestDev1 = {
      id: 'dev-001#2024-01-01T00:01:00.000Z',
      data: {
        dynamic: {
          'battery.temp': [{ value: Buffer.from('25.0') }],
        },
      },
    };
    const latestDev2 = {
      id: 'dev-002#2024-01-01T00:00:30.000Z',
      data: {
        static: { index: [{ value: Buffer.from('7') }] },
      },
    };

    const mockTable = {
      createReadStream: jest.fn().mockReturnValue(makeStream(keyRows)),
      getRows: jest.fn()
        .mockResolvedValueOnce([[latestDev1]])
        .mockResolvedValueOnce([[latestDev2]]),
    };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDevices();

    expect(result).toHaveLength(2);

    const dev1 = result.find(d => d.deviceId === 'dev-001')!;
    expect(dev1.lastSeen).toBe('2024-01-01T00:01:00.000Z');
    expect(dev1.columns).toEqual({ 'dynamic:battery.temp': '25.0' });

    const dev2 = result.find(d => d.deviceId === 'dev-002')!;
    expect(dev2.columns).toEqual({ 'static:index': '7' });
  });

  it('calls getRows with reversed:true and limit:1 per device', async () => {
    const keyRows = [{ id: 'dev-001#2024-01-01T00:00:00.000Z' }];
    const latestRow = {
      id: 'dev-001#2024-01-01T00:00:00.000Z',
      data: { dynamic: { temp: [{ value: Buffer.from('20') }] } },
    };

    const mockTable = {
      createReadStream: jest.fn().mockReturnValue(makeStream(keyRows)),
      getRows: jest.fn().mockResolvedValueOnce([[latestRow]]),
    };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    await getDevices();

    expect(mockTable.getRows).toHaveBeenCalledWith(
      expect.objectContaining({ reversed: true, limit: 1 })
    );
  });
});
