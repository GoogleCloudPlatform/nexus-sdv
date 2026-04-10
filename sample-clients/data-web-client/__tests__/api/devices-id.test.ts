import { GET } from '@/app/api/devices/[id]/route';
import { getServerSession } from 'next-auth';
import { getDeviceTimeSeries } from '@/lib/device-detail';
import { getAllowedVehicleIds } from '@/lib/acl';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/device-detail');
jest.mock('@/lib/acl');

function makeRequest(id: string, range?: string) {
  const url = `http://localhost/api/devices/${id}${range ? `?range=${range}` : ''}`;
  return new Request(url);
}

describe('GET /api/devices/[id]', () => {
  beforeEach(() => {
    // Default: user has access to dev-001.
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(['dev-001']);
  });

  it('returns 401 when not authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(null);

    const res = await GET(makeRequest('dev-001'), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(res.status).toBe(401);
  });

  it('returns 404 when device is not in the allowed set', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(['dev-999']);

    const res = await GET(makeRequest('dev-001'), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(res.status).toBe(404);
  });

  it('returns 400 for invalid device ID containing #', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });

    const res = await GET(makeRequest('dev#001'), { params: Promise.resolve({ id: 'dev#001' }) });

    expect(res.status).toBe(400);
  });

  it('returns time-series data with default range 1h', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: ['dynamic:temp'], rows: [],
    });

    const res = await GET(makeRequest('dev-001'), { params: Promise.resolve({ id: 'dev-001' }) });
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.deviceId).toBe('dev-001');
    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h');
  });

  it('passes valid range param through', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: [], rows: [],
    });

    await GET(makeRequest('dev-001', '7d'), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '7d');
  });

  it('defaults to 1h for invalid range values', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: [], rows: [],
    });

    await GET(makeRequest('dev-001', 'invalid'), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h');
  });

  it('returns 500 when getDeviceTimeSeries throws', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockRejectedValue(new Error('bigtable down'));

    const res = await GET(makeRequest('dev-001'), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(res.status).toBe(500);
  });
});
