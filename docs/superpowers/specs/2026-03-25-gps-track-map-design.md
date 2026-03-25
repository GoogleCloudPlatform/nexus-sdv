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
- `GpsTrackMap` is a client component and must include `"use client"` at the top of the file.

## Architecture

### Files changed

| File | Change |
|---|---|
| `src/components/gps-track-map.tsx` | New component (`"use client"`) |
| `src/app/device/[id]/page.tsx` | GPS detection, data extraction, render map below table |
| `.env.local` / `.env.local.example` | Add `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` |
| `package.json` | Add `@vis.gl/react-google-maps` |

### New type

```ts
interface GpsPoint {
  timestamp: string; // ISO 8601, validated non-empty and parseable before inclusion
  lat: number;
  lng: number;
  alt: number;       // Stored for future elevation profile use; not rendered in this iteration
}
```

## Data Flow

1. After the `/api/devices/[id]` response resolves, inspect `detail.columns`.
2. **Detect GPS presence:** search all column keys for entries whose qualifier portion (the substring after the first `:`) matches each of `gps.latitude`, `gps.longitude`, and `gps.altitude` — compared case-insensitively. Detection is family-agnostic: any family (`dynamic:`, `telemetry:`, etc.) is accepted as long as all three qualifiers are found. Store the exact matching keys (original casing from `detail.columns`) for use in step 3.
3. **Extract `GpsPoint[]`:** iterate `detail.rows`; for each row look up values using the exact column keys found in step 2. Skip rows where:
   - any of the three values is missing or an empty string
   - `lat`, `lng`, or `alt` does not parse to a finite number
   - `timestamp` is missing, empty, or does not parse to a valid `Date` (`isNaN(new Date(timestamp).getTime())`)
4. Sort the resulting array by `timestamp` ascending using epoch comparison: `new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime()`. String sort is not used because mixed timezone offsets sort incorrectly.
5. Pass the sorted array as a prop to `<GpsTrackMap points={gpsPoints} />`, rendered below `<DataTable>`.

## Component: `GpsTrackMap`

```
Props: { points: GpsPoint[] }
```

### Guard conditions (evaluated top-to-bottom, return `null` if triggered)

1. `!process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` → return `null`. In `NODE_ENV !== 'production'`, emit `console.warn('GpsTrackMap: NEXT_PUBLIC_GOOGLE_MAPS_API_KEY is not set')` before returning. Note: `NEXT_PUBLIC_` variables are inlined at build time — this is a build-time constant check, not a live runtime lookup.
2. `points.length === 0` → return `null`.

### Rendering

- `"use client"` directive at top of file.
- Wraps content in `<APIProvider apiKey={process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY}>`.
- Renders a `<Map>` at fixed height `400px`.
- **Multiple points (`points.length >= 2`):**
  - Renders a `<Polyline>` connecting all points in the sorted order.
  - Auto-fits map bounds to the bounding box of all points using `useMapsLibrary('core')` `LatLngBounds`. While the library is loading (async), the map renders at a default world view.
  - Renders a green `<AdvancedMarker>` at `points[0]` (earliest timestamp = journey start). Color applied via a `<Pin>` child: `<AdvancedMarker><Pin background="#22c55e" /></AdvancedMarker>`.
  - Renders a red `<AdvancedMarker>` at `points[points.length - 1]` (latest timestamp = most recent position). Color: `<Pin background="#ef4444" />`.
  - `center` and `zoom` props on `<Map>` are left uncontrolled; bounds-fitting via `LatLngBounds` is the sole positioning mechanism.
- **Single point (`points.length === 1`):**
  - No polyline rendered.
  - Map centers on the single point with zoom level 15.
  - Renders a single `<AdvancedMarker>` at that point.

### Height

Fixed at `400px`. No user-resizable behaviour in this iteration.

## Error Handling

| Scenario | Behaviour |
|---|---|
| API key missing (production) | Component returns `null` — map section not rendered |
| API key missing (development) | `console.warn` emitted, component returns `null` |
| No GPS columns in data | Map section not rendered |
| GPS columns present, no valid rows | `points` is empty → component returns `null` |
| Single valid GPS point | Single pin at zoom 15, no polyline |
| Maps library not yet loaded | Map renders at default world view until bounds are fitted |

## Out of Scope

- Clicking a map point to highlight the corresponding table row (future).
- Altitude chart / elevation profile (future — `alt` is extracted in anticipation of this).
- Clustering for dense tracks (future).
- Map style theming (Catppuccin / dark mode) — left for a follow-up.
