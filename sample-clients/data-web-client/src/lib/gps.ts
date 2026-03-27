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
  alt: string;
}

function findGpsKeys(columns: string[]): GpsKeys | null {
  const find = (qualifier: string) =>
    columns.find((col) => {
      const colon = col.indexOf(':');
      const q = colon > -1 ? col.slice(colon + 1) : col;
      return q.toLowerCase() === qualifier;
    });

  const latKey = find('gps.latitude');
  const lngKey = find('gps.longitude');
  const altKey = find('gps.altitude');

  if (!latKey || !lngKey || !altKey) return null;
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
    const altStr = row.values[keys.alt];

    if (!latStr || !lngStr || !altStr) continue;

    const strip = (s: string) => s.replace(/^"|"$/g, '');
    const lat = Number(strip(latStr));
    const lng = Number(strip(lngStr));
    const alt = Number(strip(altStr));

    if (!isFinite(lat) || !isFinite(lng) || !isFinite(alt)) continue;

    points.push({ timestamp, lat, lng, alt });
  }

  return points.sort(
    (a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime(),
  );
}
