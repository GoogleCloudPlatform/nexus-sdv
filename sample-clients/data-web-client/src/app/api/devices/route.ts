import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getDevices } from '@/lib/devices';
import { getAllowedVehicleIds } from '@/lib/acl';

export async function GET() {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const allowedIds = await getAllowedVehicleIds(session.groups);
    const devices = await getDevices(allowedIds);
    return NextResponse.json({ devices });
  } catch (err) {
    console.error('[/api/devices]', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
