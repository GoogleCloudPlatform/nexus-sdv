import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions, ADMIN_ROLE } from '@/lib/auth';
import { getAllowedVehicleIds } from '@/lib/acl';
import { getVins } from '@/lib/registry';

export async function GET() {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const vins = await getVins();
    if (vins === undefined) {
      return NextResponse.json({ vins: [], unfiltered: false, unavailable: true });
    }

    // nexus-admin sees every identity — including the ones that belong to no
    // group at all, such as failed issuances, which are exactly the entries an
    // operator needs to see. Everyone else sees only their own group's vehicles.
    if (session.roles?.includes(ADMIN_ROLE)) {
      return NextResponse.json({ vins, unfiltered: true });
    }

    const allowed = await getAllowedVehicleIds(session.groups);
    if (allowed === undefined) {
      // No ACL database configured: fall back to showing nothing rather than
      // everything — this endpoint lists identities, not public data.
      return NextResponse.json({ vins: [], unfiltered: false });
    }
    const allowedSet = new Set(allowed);
    return NextResponse.json({
      vins: vins.filter((v) => allowedSet.has(v.vin)),
      unfiltered: false,
    });
  } catch (err) {
    console.error('[/api/registry/vins]', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
