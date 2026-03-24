import { GET } from '@/app/api/devices/[id]/route';
import { getServerSession } from 'next-auth';
import { getDeviceTimeSeries } from '@/lib/device-detail';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/device-detail');

function makeRequest(id: string, range?: string) {
  const url = `http://localhost/api/devices/${id}${range ? `?range=${range}` : ''}`;
  return { url } as Request;
}

describe('GET /api/devices/[id]', () => {
  it('returns 401 when not authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(null);

    const res = await GET(makeRequest('dev-001'), { params: { id: 'dev-001' } });

    expect(res.status).toBe(401);
  });

  it('returns time-series data with default range 1h', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: ['dynamic:temp'], rows: [],
    });

    const res = await GET(makeRequest('dev-001'), { params: { id: 'dev-001' } });
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.deviceId).toBe('dev-001');
    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h');
  });

  it('passes valid range param through', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: [], rows: [],
    });

    await GET(makeRequest('dev-001', '7d'), { params: { id: 'dev-001' } });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '7d');
  });

  it('defaults to 1h for invalid range values', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: [], rows: [],
    });

    await GET(makeRequest('dev-001', 'invalid'), { params: { id: 'dev-001' } });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h');
  });
});
