# Data Web Client

A sample telemetry visualization client for Nexus SDV. It connects to your BigTable telemetry store and renders a fleet overview and per-device time-series view, with built-in support for GPS track maps.

## What it does

| Page | Path | Description |
|------|------|-------------|
| Fleet overview | `/fleet` | Table of all devices with their latest telemetry values |
| Device detail | `/device/[id]` | Time-series table + GPS track map for a single device |

Authentication is handled by Keycloak (OIDC). All BigTable access runs server-side through Next.js API routes — the browser never holds cloud credentials.

## Architecture

```
Browser → NextAuth session (OIDC cookie)
       → Next.js API routes (/api/devices, /api/devices/[id])
       → lib/ (business logic)
       → Google BigTable
```

## BigTable data model

Row key format: `{deviceId}#{ISO8601_timestamp}`

Example: `vehicle-42#2026-04-20T08:00:00.000Z`

Column values are stored as plain strings under any column family. The client reads every column family and exposes qualifiers in `family:qualifier` format (e.g. `dynamic:battery.temp`). The family prefix is stripped in the UI display.

### Known qualifier conventions

| Qualifier | Type | Used by |
|-----------|------|---------|
| `gps.latitude` | float string | GPS track map |
| `gps.longitude` | float string | GPS track map |
| `gps.altitude` | float string | GPS track map |

All other qualifiers are displayed as raw strings in the time-series table. You can store them in any column family.

## Setup

### Prerequisites

- Node.js 20+
- A running Nexus platform instance (provides Keycloak, BigTable, and all cloud infrastructure)

### Environment variables

Copy `.env.local.example` to `.env.local` and fill in the values from your Nexus deployment:

```env
NEXTAUTH_SECRET=          # openssl rand -base64 32
NEXTAUTH_URL=             # http://localhost:3000 for local dev

KEYCLOAK_CLIENT_ID=       # OIDC client ID in your realm
KEYCLOAK_CLIENT_SECRET=   # Client secret
KEYCLOAK_ISSUER=          # https://keycloak.example.com/realms/your-realm

BIGTABLE_PROJECT_ID=      # GCP project containing your BigTable instance
BIGTABLE_INSTANCE_ID=     # BigTable instance ID

NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=   # Required for GPS track map
NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID=    # Required for AdvancedMarker support
```

### Run locally

```bash
npm install
npm run dev
```

Open http://localhost:3000.

## Adding a new data domain

The GPS track map is a good template for adding richer views for other qualifier groups. The pattern has four steps:

**1. Name your qualifiers** using dot-notation under a common prefix, e.g. `engine.rpm`, `engine.temp`, `engine.torque`. Any column family works.

**2. Write an extractor** in `src/lib/` following the GPS pattern:

```typescript
// src/lib/engine.ts
import type { DeviceDetailResponse } from '@/types/telemetry';

export interface EnginePoint {
  timestamp: string;
  rpm: number;
  temp: number;
}

export function extractEnginePoints(detail: DeviceDetailResponse): EnginePoint[] {
  const find = (q: string) =>
    detail.columns.find((col) => {
      const colon = col.indexOf(':');
      return (colon > -1 ? col.slice(colon + 1) : col).toLowerCase() === q;
    });

  const rpmKey = find('engine.rpm');
  const tempKey = find('engine.temp');
  if (!rpmKey || !tempKey) return [];

  return detail.rows
    .filter((row) => row.values[rpmKey] && row.values[tempKey])
    .map((row) => ({
      timestamp: row.timestamp,
      rpm: Number(row.values[rpmKey]),
      temp: Number(row.values[tempKey]),
    }))
    .sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime());
}
```

**3. Write a component** in `src/components/` that accepts `detail: DeviceDetailResponse`, calls your extractor, and returns `null` if the qualifiers are absent. This keeps the feature purely additive — devices without those columns are unaffected.

**4. Mount it** in `src/app/device/[id]/page.tsx` alongside the existing `GpsTrackMap`.

## Running tests

```bash
npm test
```

Tests live in `__tests__/` and mirror the `src/` structure. Each lib function and API route has a unit test; use the GPS tests as a template for new extractors.
