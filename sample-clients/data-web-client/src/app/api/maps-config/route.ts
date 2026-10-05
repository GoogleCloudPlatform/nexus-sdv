import { NextResponse } from 'next/server';

/**
 * Returns Google Maps configuration values to client components at runtime.
 *
 * GOOGLE_MAPS_API_KEY and GOOGLE_MAPS_MAP_ID are plain (non-NEXT_PUBLIC_) env
 * vars injected by the Helm deployment from Secret Manager.  They are never
 * inlined into the JS bundle — only served here on demand, over the same
 * authenticated connection the browser already uses for the app.
 */
// The bootstrap stores the sentinel 'UNSET' when no Maps key is configured,
// because Secret Manager rejects an empty value. Without translating it back,
// the map would load with 'UNSET' as its key and render a Google error instead
// of staying hidden.
const UNSET = 'UNSET';

export async function GET() {
  const rawKey = process.env.GOOGLE_MAPS_API_KEY ?? '';
  const rawMapId = process.env.GOOGLE_MAPS_MAP_ID ?? '';
  const apiKey = rawKey === UNSET ? '' : rawKey;
  const mapId = rawMapId === '' || rawMapId === UNSET ? 'DEMO_MAP_ID' : rawMapId;
  return NextResponse.json({ apiKey, mapId });
}
