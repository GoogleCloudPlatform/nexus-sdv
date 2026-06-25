import { NextResponse } from 'next/server';

/**
 * Returns Google Maps configuration values to client components at runtime.
 *
 * GOOGLE_MAPS_API_KEY and GOOGLE_MAPS_MAP_ID are plain (non-NEXT_PUBLIC_) env
 * vars injected by the Helm deployment from Secret Manager.  They are never
 * inlined into the JS bundle — only served here on demand, over the same
 * authenticated connection the browser already uses for the app.
 */
export async function GET() {
  const apiKey = process.env.GOOGLE_MAPS_API_KEY ?? '';
  const mapId = process.env.GOOGLE_MAPS_MAP_ID ?? 'DEMO_MAP_ID';
  return NextResponse.json({ apiKey, mapId });
}
