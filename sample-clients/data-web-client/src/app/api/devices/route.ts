import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getDevices } from '@/lib/devices';

export async function GET() {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const devices = await getDevices();
    return NextResponse.json({ devices });
  } catch {
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
