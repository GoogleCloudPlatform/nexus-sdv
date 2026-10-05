import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions, ADMIN_ROLE } from '@/lib/auth';
import { getAllowedVehicleIds } from '@/lib/acl';
import { getVinEvents } from '@/lib/registry';

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ vin: string }> },
) {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const { vin } = await params;

  try {
    // A detail route is a second door to the data the list view filters, so the
    // access check happens here before anything is read. A vehicle the caller
    // may not see answers 404, not 403 — following the device detail route: a
    // user who may not see a vehicle must not learn that it exists.
    if (!session.roles?.includes(ADMIN_ROLE)) {
      const allowed = await getAllowedVehicleIds(session.groups);
      // No ACL database configured: show nothing rather than everything, as the
      // list route does. For a single vehicle "nothing" is 404 — there is no
      // empty version of one identity.
      if (allowed === undefined || !allowed.includes(vin)) {
        return NextResponse.json({ error: 'Not found' }, { status: 404 });
      }
    }

    const events = await getVinEvents(vin);
    if (events === undefined) {
      return NextResponse.json({ vin, events: [], unavailable: true });
    }

    return NextResponse.json({ vin, events });
  } catch (err) {
    console.error('[/api/registry/vins/[vin]/events]', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
