import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getDeviceTimeSeries, DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE } from '@/lib/device-detail';
import { getAllowedVehicleIds } from '@/lib/acl';
import type { TimeRange } from '@/types/telemetry';

const VALID_RANGES = new Set<TimeRange>(['1h', '6h', '24h', '7d']);

function parseRange(value: string | null): TimeRange {
  if (value && VALID_RANGES.has(value as TimeRange)) return value as TimeRange;
  return '1h';
}

function parsePageSize(value: string | null): number {
  const n = parseInt(value ?? '', 10);
  if (!Number.isFinite(n) || n < 1) return DEFAULT_PAGE_SIZE;
  return Math.min(n, MAX_PAGE_SIZE);
}

function parseCursor(value: string | null): string | undefined {
  if (!value) return undefined;
  try {
    return Buffer.from(value, 'base64').toString('utf8');
  } catch {
    return undefined;
  }
}

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const { id } = await params;

  if (!id || id.includes('#')) {
    return NextResponse.json({ error: 'Invalid device ID' }, { status: 400 });
  }

  try {
    const allowedIds = await getAllowedVehicleIds(session.groups);
    if (allowedIds !== undefined && !allowedIds.includes(id)) {
      return NextResponse.json({ error: 'Not found' }, { status: 404 });
    }

    const { searchParams } = new URL(request.url);
    const range = parseRange(searchParams.get('range'));
    const pageSize = parsePageSize(searchParams.get('pageSize'));
    const cursor = parseCursor(searchParams.get('cursor'));

    const data = await getDeviceTimeSeries(id, range, cursor, pageSize);
    return NextResponse.json(data);
  } catch (err) {
    console.error('[/api/devices/[id]]', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
