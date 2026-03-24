import { GET } from '@/app/api/devices/route';
import { getServerSession } from 'next-auth';
import { getDevices } from '@/lib/devices';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/devices');

describe('GET /api/devices', () => {
  it('returns 401 when not authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(null);

    const res = await GET();
    const body = await res.json();

    expect(res.status).toBe(401);
    expect(body.error).toBe('Unauthorized');
  });

  it('returns 500 when getDevices throws', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDevices as jest.Mock).mockRejectedValue(new Error('bigtable down'));

    const res = await GET();

    expect(res.status).toBe(500);
  });

  it('returns device list when authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDevices as jest.Mock).mockResolvedValue([
      { deviceId: 'dev-001', lastSeen: '2024-01-01T00:00:00Z', columns: {} },
    ]);

    const res = await GET();
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.devices).toHaveLength(1);
    expect(body.devices[0].deviceId).toBe('dev-001');
  });
});
