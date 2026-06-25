import { GET } from '@/app/api/devices/[id]/route';
import { getServerSession } from 'next-auth';
import { getDeviceTimeSeries } from '@/lib/device-detail';
import { getAllowedVehicleIds } from '@/lib/acl';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/device-detail');
jest.mock('@/lib/acl');

function makeRequest(id: string, params: Record<string, string> = {}) {
  const url = new URL(`http://localhost/api/devices/${id}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  return new Request(url.toString());
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
      deviceId: 'dev-001', columns: ['dynamic:temp'], rows: [], hasMore: false, nextCursor: null,
    });

    const res = await GET(makeRequest('dev-001'), { params: Promise.resolve({ id: 'dev-001' }) });
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.deviceId).toBe('dev-001');
    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h', undefined, 25);
  });

  it('passes valid range param through', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({ deviceId: 'dev-001', columns: [], rows: [], hasMore: false, nextCursor: null });

    await GET(makeRequest('dev-001', { range: '7d' }), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '7d', undefined, 25);
  });

  it('defaults to 1h for invalid range values', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({ deviceId: 'dev-001', columns: [], rows: [], hasMore: false, nextCursor: null });

    await GET(makeRequest('dev-001', { range: 'invalid' }), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h', undefined, 25);
  });

  it('passes cursor and pageSize through to getDeviceTimeSeries', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({ deviceId: 'dev-001', columns: [], rows: [], hasMore: false, nextCursor: null });

    const rawKey = 'dev-001#2024-01-01T00:00:00.000Z';
    const encodedCursor = Buffer.from(rawKey).toString('base64');

    await GET(makeRequest('dev-001', { cursor: encodedCursor, pageSize: '10' }), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h', rawKey, 10);
  });

  it('clamps pageSize to MAX_PAGE_SIZE', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({ deviceId: 'dev-001', columns: [], rows: [], hasMore: false, nextCursor: null });

    await GET(makeRequest('dev-001', { pageSize: '9999' }), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h', undefined, 200);
  });

  it('returns 500 when getDeviceTimeSeries throws', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' }, groups: ['fleet-a'] });
    (getDeviceTimeSeries as jest.Mock).mockRejectedValue(new Error('bigtable down'));

    const res = await GET(makeRequest('dev-001'), { params: Promise.resolve({ id: 'dev-001' }) });

    expect(res.status).toBe(500);
  });
});
