import type { DeviceDetailResponse } from '@/types/telemetry';

export interface GpsPoint {
  timestamp: string;
  lat: number;
  lng: number;
  alt: number; // stored for future elevation profile; not rendered in this iteration
}

interface GpsKeys {
  lat: string;
  lng: string;
  alt: string | null; // null when the column is absent; altitude defaults to 0
}

// Accepted qualifier names for each axis (case-insensitive, any column family).
// Covers both dot-separated style (gps.latitude) and the uppercase underscore
// style produced by the nats-bigtable-connector (GPS_LATITUDE).
const LAT_QUALIFIERS = ['gps.latitude', 'gps_latitude'];
const LNG_QUALIFIERS = ['gps.longitude', 'gps_longitude'];
const ALT_QUALIFIERS = ['gps.altitude', 'gps_altitude'];

function findGpsKeys(columns: string[]): GpsKeys | null {
  const find = (qualifiers: string[]) =>
    columns.find((col) => {
      const colon = col.indexOf(':');
      const q = (colon > -1 ? col.slice(colon + 1) : col).toLowerCase();
      return qualifiers.includes(q);
    });

  const latKey = find(LAT_QUALIFIERS);
  const lngKey = find(LNG_QUALIFIERS);
  const altKey = find(ALT_QUALIFIERS) ?? null;

  if (!latKey || !lngKey) return null;
  return { lat: latKey, lng: lngKey, alt: altKey };
}

export function extractGpsPoints(detail: DeviceDetailResponse): GpsPoint[] {
  const keys = findGpsKeys(detail.columns);
  if (!keys) return [];

  const points: GpsPoint[] = [];

  for (const row of detail.rows) {
    const { timestamp } = row;
    if (!timestamp || isNaN(new Date(timestamp).getTime())) continue;

    const latStr = row.values[keys.lat];
    const lngStr = row.values[keys.lng];
    const altStr = keys.alt ? row.values[keys.alt] : null;

    if (!latStr || !lngStr) continue;

    // Values may be bare strings or JSON-encoded strings (e.g. "\"41.49\"").
    // parseNumeric handles both.
    const parseNumeric = (s: string): number => {
      const stripped = s.replace(/^"+|"+$/g, '');
      return Number(stripped);
    };

    const lat = parseNumeric(latStr);
    const lng = parseNumeric(lngStr);
    const alt = altStr ? parseNumeric(altStr) : 0;

    if (!isFinite(lat) || !isFinite(lng) || !isFinite(alt)) continue;

    points.push({ timestamp, lat, lng, alt });
  }

  return points.sort(
    (a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime(),
  );
}
