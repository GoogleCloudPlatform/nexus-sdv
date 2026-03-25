# GPS Track Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Google Maps GPS track visualisation below the telemetry table on the device detail page, shown only when `gps.latitude`, `gps.longitude`, and `gps.altitude` columns are present in the response.

**Architecture:** A new `extractGpsPoints` utility handles GPS detection and extraction from the device detail response. A new `GpsTrackMap` client component renders the map using `@vis.gl/react-google-maps`. The device detail page calls the utility and conditionally renders the map below the existing data table.

**Tech Stack:** Next.js 16.2.1 (App Router), React 19, TypeScript, `@vis.gl/react-google-maps`, Tailwind CSS, Jest + React Testing Library

---

## File Map

| File | Change |
|---|---|
| `sample-clients/data-web-client/package.json` | Add `@vis.gl/react-google-maps` dependency |
| `sample-clients/data-web-client/.env.local.example` | Add `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` |
| `sample-clients/data-web-client/src/lib/gps.ts` | **New** — GPS detection + extraction utility + `GpsPoint` type |
| `sample-clients/data-web-client/src/components/gps-track-map.tsx` | **New** — client component (`"use client"`) rendering map |
| `sample-clients/data-web-client/src/app/device/[id]/page.tsx` | Wire up GPS extraction and conditional map rendering |
| `sample-clients/data-web-client/__tests__/lib/gps.test.ts` | **New** — unit tests for `extractGpsPoints` |
| `sample-clients/data-web-client/__tests__/components/gps-track-map.test.tsx` | **New** — component tests for `GpsTrackMap` |

All work is done inside `sample-clients/data-web-client/`. Run all commands from there unless stated otherwise.

---

### Task 1: Install dependency and configure env

**Files:**
- Modify: `package.json`
- Modify: `.env.local.example`

- [ ] **Step 1: Install `@vis.gl/react-google-maps`**

```bash
cd sample-clients/data-web-client && npm install @vis.gl/react-google-maps
```

Expected: `@vis.gl/react-google-maps` appears in `dependencies` in `package.json`. `node_modules/@vis.gl/react-google-maps` exists.

- [ ] **Step 2: Add env var to example file**

Append to `.env.local.example`:

```
NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=your-google-maps-api-key
```

> **Note:** `NEXT_PUBLIC_` variables are inlined at build time in Next.js. The value must be present at build time, not just runtime. Set this in your actual `.env.local` before running the dev server.

> **Note on Map ID:** `AdvancedMarker` (used for start/end pins) requires a Map ID with vector rendering. For local development, use `DEMO_MAP_ID` as the mapId (hardcoded in the component). For production, replace with a real Map ID from Google Cloud Console → Maps → Map IDs.

- [ ] **Step 3: Commit**

```bash
git add package.json package-lock.json .env.local.example
git commit -m "feat: add @vis.gl/react-google-maps dependency"
```

---

### Task 2: GPS extraction utility (TDD)

**Files:**
- Create: `src/lib/gps.ts`
- Create: `__tests__/lib/gps.test.ts`

Tests go in `__tests__/lib/` (node environment). Run with `npm test -- --testPathPattern="__tests__/lib/gps" --no-coverage`.

- [ ] **Step 1: Write failing tests**

Create `__tests__/lib/gps.test.ts`:

```typescript
import { extractGpsPoints } from '@/lib/gps';
import type { DeviceDetailResponse } from '@/types/telemetry';

function makeDetail(
  columns: string[],
  rows: { timestamp: string; values: Record<string, string> }[],
): DeviceDetailResponse {
  return { deviceId: 'dev1', columns, rows };
}

describe('extractGpsPoints', () => {
  it('returns empty array when GPS columns are absent', () => {
    const detail = makeDetail(['dynamic:battery.temp'], []);
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('returns empty array when only some GPS columns present', () => {
    const detail = makeDetail(['dynamic:gps.latitude', 'dynamic:gps.longitude'], []);
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('extracts valid GPS points when all three columns present', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'dynamic:gps.latitude': '51.5',
            'dynamic:gps.longitude': '-0.1',
            'dynamic:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toEqual([
      { timestamp: '2026-03-25T10:00:00Z', lat: 51.5, lng: -0.1, alt: 10 },
    ]);
  });

  it('detects GPS columns case-insensitively', () => {
    const detail = makeDetail(
      ['dynamic:GPS.LATITUDE', 'dynamic:GPS.LONGITUDE', 'dynamic:GPS.ALTITUDE'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'dynamic:GPS.LATITUDE': '51.5',
            'dynamic:GPS.LONGITUDE': '-0.1',
            'dynamic:GPS.ALTITUDE': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toHaveLength(1);
  });

  it('detects GPS columns with any family prefix', () => {
    const detail = makeDetail(
      ['telemetry:gps.latitude', 'telemetry:gps.longitude', 'telemetry:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'telemetry:gps.latitude': '51.5',
            'telemetry:gps.longitude': '-0.1',
            'telemetry:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toHaveLength(1);
  });

  it('skips rows with missing coordinate values', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [{ timestamp: '2026-03-25T10:00:00Z', values: { 'dynamic:gps.latitude': '51.5' } }],
    );
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('skips rows with non-finite coordinate values', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'dynamic:gps.latitude': 'NaN',
            'dynamic:gps.longitude': '-0.1',
            'dynamic:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('skips rows with invalid timestamps', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: 'not-a-date',
          values: {
            'dynamic:gps.latitude': '51.5',
            'dynamic:gps.longitude': '-0.1',
            'dynamic:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('sorts points by timestamp ascending', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:01:00Z',
          values: { 'dynamic:gps.latitude': '52.0', 'dynamic:gps.longitude': '-0.2', 'dynamic:gps.altitude': '20' },
        },
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: { 'dynamic:gps.latitude': '51.5', 'dynamic:gps.longitude': '-0.1', 'dynamic:gps.altitude': '10' },
        },
      ],
    );
    const result = extractGpsPoints(detail);
    expect(result[0].timestamp).toBe('2026-03-25T10:00:00Z');
    expect(result[1].timestamp).toBe('2026-03-25T10:01:00Z');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="__tests__/lib/gps" --no-coverage
```

Expected: All 8 tests fail with `Cannot find module '@/lib/gps'`.

- [ ] **Step 3: Implement `src/lib/gps.ts`**

Create `src/lib/gps.ts`:

```typescript
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

    const lat = Number(latStr);
    const lng = Number(lngStr);
    const alt = Number(altStr);

    if (!isFinite(lat) || !isFinite(lng) || !isFinite(alt)) continue;

    points.push({ timestamp, lat, lng, alt });
  }

  return points.sort(
    (a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime(),
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="__tests__/lib/gps" --no-coverage
```

Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/gps.ts __tests__/lib/gps.test.ts
git commit -m "feat: add GPS extraction utility with tests"
```

---

### Task 3: `GpsTrackMap` component (TDD)

**Files:**
- Create: `src/components/gps-track-map.tsx`
- Create: `__tests__/components/gps-track-map.test.tsx`

Tests go in `__tests__/components/` (jsdom environment). `@vis.gl/react-google-maps` is mocked entirely — it requires browser APIs that jsdom cannot provide. Tests focus on guard logic and rendered structure.

- [ ] **Step 1: Write failing tests**

Create `__tests__/components/gps-track-map.test.tsx`:

```tsx
import { render, screen } from '@testing-library/react';
import GpsTrackMap from '@/components/gps-track-map';
import type { GpsPoint } from '@/lib/gps';

// Mock @vis.gl/react-google-maps — needs real browser + Maps JS API to function
jest.mock('@vis.gl/react-google-maps', () => ({
  APIProvider: ({ children }: { children: React.ReactNode }) => (
    <div data-testid="api-provider">{children}</div>
  ),
  Map: ({ children, style }: { children?: React.ReactNode; style?: React.CSSProperties }) => (
    <div data-testid="map" style={style}>{children}</div>
  ),
  AdvancedMarker: ({ children }: { children?: React.ReactNode }) => (
    <div data-testid="advanced-marker">{children}</div>
  ),
  Pin: ({ background }: { background: string }) => (
    <div data-testid="pin" data-background={background} />
  ),
  useMap: () => null,
  useMapsLibrary: () => null,
}));

const twoPoints: GpsPoint[] = [
  { timestamp: '2026-03-25T10:00:00Z', lat: 51.5, lng: -0.1, alt: 10 },
  { timestamp: '2026-03-25T10:01:00Z', lat: 51.6, lng: -0.2, alt: 20 },
];

const onePoint: GpsPoint[] = [
  { timestamp: '2026-03-25T10:00:00Z', lat: 51.5, lng: -0.1, alt: 10 },
];

describe('GpsTrackMap', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it('renders null when API key is missing', () => {
    delete process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    const { container } = render(<GpsTrackMap points={twoPoints} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders null when points array is empty', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    const { container } = render(<GpsTrackMap points={[]} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders map container when valid points provided', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    expect(screen.getByTestId('api-provider')).toBeInTheDocument();
    expect(screen.getByTestId('map')).toBeInTheDocument();
  });

  it('renders two markers for multi-point track', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    expect(screen.getAllByTestId('advanced-marker')).toHaveLength(2);
  });

  it('renders one marker for single point', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={onePoint} />);
    expect(screen.getAllByTestId('advanced-marker')).toHaveLength(1);
  });

  it('uses green pin for start marker and red pin for end marker', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    const pins = screen.getAllByTestId('pin');
    expect(pins[0]).toHaveAttribute('data-background', '#22c55e');
    expect(pins[1]).toHaveAttribute('data-background', '#ef4444');
  });

  it('applies 400px height to map wrapper', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    const wrapper = screen.getByTestId('map').parentElement;
    expect(wrapper).toHaveStyle({ height: '400px' });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="__tests__/components/gps-track-map" --no-coverage
```

Expected: All 7 tests fail with `Cannot find module '@/components/gps-track-map'`.

- [ ] **Step 3: Implement `src/components/gps-track-map.tsx`**

Create `src/components/gps-track-map.tsx`:

```tsx
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
          // Replace with a real Map ID from Google Cloud Console for production.
          mapId="DEMO_MAP_ID"
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="__tests__/components/gps-track-map" --no-coverage
```

Expected: All 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/gps-track-map.tsx __tests__/components/gps-track-map.test.tsx
git commit -m "feat: add GpsTrackMap component with tests"
```

---

### Task 4: Wire up device detail page

**Files:**
- Modify: `src/app/device/[id]/page.tsx`

No new tests for this task — the GPS logic is fully covered by Task 2 tests, and the component by Task 3 tests. The wiring is a minimal two-import, one-line change.

- [ ] **Step 1: Add imports**

In `src/app/device/[id]/page.tsx`, add after the existing imports:

```tsx
import { extractGpsPoints } from '@/lib/gps';
import GpsTrackMap from '@/components/gps-track-map';
```

- [ ] **Step 2: Extract GPS points from the response**

After the `tableData` declaration (around line 40), add:

```tsx
const gpsPoints = detail ? extractGpsPoints(detail) : [];
```

- [ ] **Step 3: Render map below the table**

Replace:

```tsx
{!loading && !error && detail && (
  <DataTable columnKeys={tableColumnKeys} data={tableData} />
)}
```

With:

```tsx
{!loading && !error && detail && (
  <div className="space-y-4">
    <DataTable columnKeys={tableColumnKeys} data={tableData} />
    {gpsPoints.length > 0 && <GpsTrackMap points={gpsPoints} />}
  </div>
)}
```

- [ ] **Step 4: Run full test suite**

```bash
npm test --no-coverage
```

Expected: All tests pass, no regressions.

- [ ] **Step 5: Smoke test in the browser**

```bash
npm run dev
```

Navigate to a device detail page. Verify:
- **Without GPS columns** — only the telemetry table renders. No map, no errors.
- **With GPS columns** (`gps.latitude`, `gps.longitude`, `gps.altitude` present, any family) — map renders below the table at 400px height, blue polyline connecting all positions, green start pin, red end pin.
- **Time range selector** — changing the range refetches data; map updates accordingly.

> If the map fails to render, check the browser console. Common issues:
> - Missing `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` in `.env.local` — dev console will show the warning.
> - API key not enabled for Maps JavaScript API in Google Cloud Console.
> - `AdvancedMarker` error about Map ID — `DEMO_MAP_ID` should work for dev; check the Google Maps console if not.

- [ ] **Step 6: Commit**

```bash
git add src/app/device/[id]/page.tsx
git commit -m "feat: render GPS track map on device detail page"
```
