'use client';

import { useEffect } from 'react';
import {
  APIProvider,
  Map,
  AdvancedMarker,
  Pin,
  useMap,
  useMapsLibrary,
} from '@vis.gl/react-google-maps';
import type { GpsPoint } from '@/lib/gps';

interface Props {
  points: GpsPoint[];
}

// Must be rendered inside <APIProvider><Map> to use map hooks.
// Draws the polyline track and fits map bounds to all points.
function TrackOverlay({ points }: { points: GpsPoint[] }) {
  const map = useMap();
  const mapsApi = useMapsLibrary('maps');  // google.maps.Polyline lives here
  const coreApi = useMapsLibrary('core');  // google.maps.LatLngBounds lives here

  useEffect(() => {
    if (!map || !mapsApi || points.length < 2) return;
    const polyline = new mapsApi.Polyline({
      path: points.map((p) => ({ lat: p.lat, lng: p.lng })),
      strokeColor: '#3b82f6',
      strokeWeight: 3,
      map,
    });
    return () => polyline.setMap(null);
  }, [map, mapsApi, points]);

  useEffect(() => {
    if (!map || !coreApi || points.length < 2) return;
    const bounds = new coreApi.LatLngBounds();
    points.forEach((p) => bounds.extend({ lat: p.lat, lng: p.lng }));
    map.fitBounds(bounds);
  }, [map, coreApi, points]);

  return null;
}

export default function GpsTrackMap({ points }: Props) {
  const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;

  if (!apiKey) {
    if (process.env.NODE_ENV !== 'production') {
      console.warn('GpsTrackMap: NEXT_PUBLIC_GOOGLE_MAPS_API_KEY is not set');
    }
    return null;
  }

  if (points.length === 0) return null;

  const singlePoint = points.length === 1;
  const firstPos = { lat: points[0].lat, lng: points[0].lng };
  const lastPos = { lat: points[points.length - 1].lat, lng: points[points.length - 1].lng };

  return (
    <APIProvider apiKey={apiKey}>
      <div style={{ height: '400px', width: '100%' }} className="rounded border border-gray-200 overflow-hidden">
        <Map
          style={{ width: '100%', height: '100%' }}
          defaultCenter={firstPos}
          defaultZoom={singlePoint ? 15 : 10}
          // DEMO_MAP_ID enables AdvancedMarker in development.
          // Set NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID in .env.local for a real Map ID.
          mapId={process.env.NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID ?? 'DEMO_MAP_ID'}
        >
          {!singlePoint && <TrackOverlay points={points} />}
          <AdvancedMarker position={firstPos}>
            <Pin background="#22c55e" borderColor="#16a34a" glyphColor="#fff" />
          </AdvancedMarker>
          {!singlePoint && (
            <AdvancedMarker position={lastPos}>
              <Pin background="#ef4444" borderColor="#dc2626" glyphColor="#fff" />
            </AdvancedMarker>
          )}
        </Map>
      </div>
    </APIProvider>
  );
}
