# GPS Track Map — Device Detail Page

**Date:** 2026-03-25
**Branch:** feat/devices-use-case
**Status:** Approved

## Summary

Add a Google Maps GPS track visualisation to the device detail page. The map is shown only when the telemetry data contains all three GPS column qualifiers (`gps.latitude`, `gps.longitude`, `gps.altitude`). It renders below the existing telemetry table and displays a polyline connecting all GPS positions in the selected time range.

## Motivation

Devices transmitting GPS data benefit from a spatial view of their route. The existing time-series table is sufficient for raw values but does not convey movement. A track map lets operators immediately see where a device has been within the selected time window.

## Constraints

- Google Maps JavaScript API requires a browser-side API key (`NEXT_PUBLIC_GOOGLE_MAPS_API_KEY`).
- Map must not appear when GPS columns are absent — the feature is purely additive.
- Library: `@vis.gl/react-google-maps` (TypeScript-first, hooks-based).

## Architecture

### Files changed

| File | Change |
|---|---|
| `src/components/gps-track-map.tsx` | New component |
| `src/app/device/[id]/page.tsx` | GPS detection, data extraction, render map below table |
| `.env.local` / `.env.local.example` | Add `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` |
| `package.json` | Add `@vis.gl/react-google-maps` |

### New type

```ts
interface GpsPoint {
  timestamp: string;
  lat: number;
  lng: number;
  alt: number;
}
```

## Data Flow

1. After the `/api/devices/[id]` response resolves, inspect `detail.columns`.
2. Detect GPS presence: all three of `gps.latitude`, `gps.longitude`, `gps.altitude` must appear as the qualifier portion (after `:`) of a column key — matched case-insensitively.
3. If detected, extract `GpsPoint[]` from `detail.rows`: parse lat/lng/alt to `Number`, skip rows where any value is missing or non-finite.
4. Pass the array as a prop to `<GpsTrackMap points={gpsPoints} />`, rendered below `<DataTable>`.

## Component: `GpsTrackMap`

```
Props: { points: GpsPoint[] }
```

### Rendering

- Wraps `<Map>` in `<APIProvider apiKey={process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY}>`.
- Renders a `<Polyline>` connecting all points in chronological order.
- Renders a green `<AdvancedMarker>` at `points[0]` (journey start) and a red one at `points[points.length - 1]` (most recent position).
- Map bounds auto-fit to the bounding box of all points using `useMapsLibrary('core')` `LatLngBounds`.
- If `points.length < 2`, renders a single pin at `points[0]` with no polyline.

### Guard conditions

- If `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` is empty/undefined, return `null` (silent skip, no console noise in production).
- If `points.length === 0`, return `null`.

### Height

Fixed at `400px`. No user-resizable behaviour in this iteration.

## Error Handling

| Scenario | Behaviour |
|---|---|
| API key missing | Component returns `null` — map section not rendered |
| No GPS columns in data | Map section not rendered |
| GPS columns present but all rows lack coordinates | `points` is empty → component returns `null` |
| Single GPS point | Single pin, no polyline |

## Out of Scope

- Clicking a map point to highlight the corresponding table row (future).
- Altitude chart / elevation profile (future).
- Clustering for dense tracks (future).
- Map style theming (Catppuccin / dark mode) — left for a follow-up.
