import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getDeviceTimeSeries } from '@/lib/device-detail';
import type { TimeRange } from '@/types/telemetry';

const VALID_RANGES = new Set<TimeRange>(['1h', '6h', '24h', '7d']);

function parseRange(value: string | null): TimeRange {
  if (value && VALID_RANGES.has(value as TimeRange)) return value as TimeRange;
  return '1h';
}

export async function GET(
  request: Request,
  { params }: { params: { id: string } },
) {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const { searchParams } = new URL(request.url);
  const range = parseRange(searchParams.get('range'));

  const data = await getDeviceTimeSeries(params.id, range);
  return NextResponse.json(data);
}
