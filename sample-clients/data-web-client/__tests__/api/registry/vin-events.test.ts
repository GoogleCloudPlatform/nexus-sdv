import { GET } from '@/app/api/registry/vins/[vin]/events/route';
import { getServerSession } from 'next-auth';
import { getAllowedVehicleIds } from '@/lib/acl';
import { getVinEvents } from '@/lib/registry';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/acl');
jest.mock('@/lib/registry');

const EVENTS = [
  { created_at: '2026-09-22T10:00:00Z', action: 'operational-certificate-issued', source: 'registration', result: 'success' },
  { created_at: '2026-09-21T10:00:00Z', action: 'factory-certificate-issued', source: 'factory-helper', result: 'success' },
];

const session = (roles: string[], groups: string[] = ['nexus-fleet']) => ({
  user: { email: 'a@test.com' }, groups, roles,
});

function request(vin: string) {
  return new Request(`http://localhost/api/registry/vins/${vin}/events`);
}

const call = (vin: string) => GET(request(vin), { params: Promise.resolve({ vin }) });

describe('GET /api/registry/vins/[vin]/events', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns 401 when not authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(null);

    expect((await call('VEHICLE001')).status).toBe(401);
  });

  it('lets nexus-admin read a vin that belongs to no group', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session(['nexus-admin']));
    (getVinEvents as jest.Mock).mockResolvedValue(EVENTS);

    const res = await call('FAILED001');
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.vin).toBe('FAILED001');
    expect(body.events).toHaveLength(2);
    expect(getAllowedVehicleIds).not.toHaveBeenCalled();
  });

  it('lets a group member read a vin in their own group', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session([]));
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(['VEHICLE001']);
    (getVinEvents as jest.Mock).mockResolvedValue(EVENTS);

    const res = await call('VEHICLE001');
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.events.map((e: { action: string }) => e.action)).toEqual([
      'operational-certificate-issued',
      'factory-certificate-issued',
    ]);
  });

  it('answers 404, not 403, for a vin outside the caller groups', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session([]));
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(['VEHICLE001']);

    const res = await call('VEHICLE002');

    // 403 would confirm the vehicle exists. It must not be distinguishable
    // from a vin the registry has never seen.
    expect(res.status).toBe(404);
    expect(getVinEvents).not.toHaveBeenCalled();
  });

  it('shows nothing rather than everything when no ACL database is configured', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session([]));
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(undefined);

    const res = await call('VEHICLE001');

    expect(res.status).toBe(404);
    expect(getVinEvents).not.toHaveBeenCalled();
  });

  it('returns an empty history for a vin the registry has never seen', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session(['nexus-admin']));
    (getVinEvents as jest.Mock).mockResolvedValue([]);

    const res = await call('UNKNOWN001');
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.events).toEqual([]);
  });

  it('reports unavailable when no registry is configured', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session(['nexus-admin']));
    (getVinEvents as jest.Mock).mockResolvedValue(undefined);

    const res = await call('VEHICLE001');
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.unavailable).toBe(true);
    expect(body.events).toEqual([]);
  });

  it('returns 500 when the registry call fails', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session(['nexus-admin']));
    (getVinEvents as jest.Mock).mockRejectedValue(new Error('registry down'));

    expect((await call('VEHICLE001')).status).toBe(500);
  });
});
