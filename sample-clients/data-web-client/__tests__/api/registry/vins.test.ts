import { GET } from '@/app/api/registry/vins/route';
import { getServerSession } from 'next-auth';
import { getAllowedVehicleIds } from '@/lib/acl';
import { getVins } from '@/lib/registry';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/acl');
jest.mock('@/lib/registry');

const VINS = [
  { vin: 'VEHICLE001', events: 1, first_seen: 'a', last_seen: 'a', last_action: 'operational-certificate-issued', last_result: 'success' },
  { vin: 'VEHICLE002', events: 1, first_seen: 'a', last_seen: 'a', last_action: 'factory-certificate-issued', last_result: 'success' },
  // Recorded but never enrolled into any group — the case that makes the admin
  // role earn its place even with a single fleet.
  { vin: 'FAILED001', events: 1, first_seen: 'a', last_seen: 'a', last_action: 'factory-certificate-issued', last_result: 'failure' },
];

const session = (roles: string[], groups: string[] = ['nexus-fleet']) => ({
  user: { email: 'a@test.com' }, groups, roles,
});

describe('GET /api/registry/vins', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns 401 when not authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(null);
    const res = await GET();
    expect(res.status).toBe(401);
  });

  it('shows every identity to nexus-admin, including ones in no group', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session(['nexus-admin']));
    (getVins as jest.Mock).mockResolvedValue(VINS);

    const body = await (await GET()).json();

    expect(body.unfiltered).toBe(true);
    expect(body.vins.map((v: { vin: string }) => v.vin)).toEqual(['VEHICLE001', 'VEHICLE002', 'FAILED001']);
    expect(getAllowedVehicleIds).not.toHaveBeenCalled();
  });

  it('restricts a non-admin to the vehicles of their own group', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session([]));
    (getVins as jest.Mock).mockResolvedValue(VINS);
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(['VEHICLE001']);

    const body = await (await GET()).json();

    expect(body.unfiltered).toBe(false);
    expect(body.vins.map((v: { vin: string }) => v.vin)).toEqual(['VEHICLE001']);
  });

  it('does not leak an unenrolled vin to a non-admin', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session([]));
    (getVins as jest.Mock).mockResolvedValue(VINS);
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(['VEHICLE001', 'VEHICLE002']);

    const body = await (await GET()).json();

    expect(body.vins.map((v: { vin: string }) => v.vin)).not.toContain('FAILED001');
  });

  it('shows nothing rather than everything when no ACL database is configured', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session([]));
    (getVins as jest.Mock).mockResolvedValue(VINS);
    (getAllowedVehicleIds as jest.Mock).mockResolvedValue(undefined);

    const body = await (await GET()).json();

    expect(body.vins).toEqual([]);
  });

  it('reports unavailable when no registry is configured', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session(['nexus-admin']));
    (getVins as jest.Mock).mockResolvedValue(undefined);

    const res = await GET();
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.unavailable).toBe(true);
    expect(body.vins).toEqual([]);
  });

  it('returns 500 when the registry call fails', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(session(['nexus-admin']));
    (getVins as jest.Mock).mockRejectedValue(new Error('registry down'));

    expect((await GET()).status).toBe(500);
  });
});
