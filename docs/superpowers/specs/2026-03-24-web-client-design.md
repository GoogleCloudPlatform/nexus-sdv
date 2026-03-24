# Web Client Design Spec

**Date:** 2026-03-24
**Project:** `sample-clients/data-web-client`
**Status:** Approved

---

## Overview

A Next.js web dashboard for browsing telemetry data stored in Google BigTable. Provides a fleet overview (one row per device, latest reading) with drill-down to a per-device time-series view. Access is restricted to Google Workspace users via OAuth.

---

## Goals

- Display BigTable telemetry data in a tabular view
- Restrict access to Google Workspace members (enforced at the OAuth client level)
- Support two distinct data domains: automotive (partner use case) and IoT (Seibert use case) — handled automatically via dynamic column discovery
- Provide a foundation for incremental feature additions (e.g. GPS/Maps integration)

---

## Out of Scope (v1)

- Real-time auto-refresh
- Charts or visualisations
- GPS/Maps integration (planned future increment)
- User roles or per-device access control
- Mobile-optimised layout

---

## Architecture

### Approach

Standalone Next.js App Router application. API routes act as a thin BFF (Backend For Frontend) that query BigTable directly using the Node.js SDK with Application Default Credentials. React components only call internal `/api/*` routes — they have no direct dependency on BigTable.

This keeps a clean migration path: if the data access layer is later moved to a dedicated Go service, only the API route bodies change; the UI layer is untouched.

### Stack

| Dependency | Purpose |
|---|---|
| `next` (App Router, TypeScript) | Framework |
| `next-auth` | Google OAuth, session management |
| `@google-cloud/bigtable` | BigTable Node.js SDK |
| `@tanstack/react-table` | Headless table with dynamic columns |
| `tailwindcss` | Styling |

### Deployment

- **Now:** Local development using `gcloud auth application-default login` (ADC)
- **Future:** GKE with Workload Identity Federation (no service account key files needed — credential source swap only)

---

## Authentication & Authorisation

- **Provider:** NextAuth.js with Google OAuth
- **Restriction:** GCP OAuth client configured as **Internal** — Google enforces Workspace-only sign-in at the identity provider level; no application-side domain filtering required
- **Session:** Stored in a signed cookie (NextAuth default)
- **Protection:** All `/api/*` routes call `getServerSession()` and return `401` if no valid session exists. UI pages (`/fleet`, `/device/[id]`) are protected via a `middleware.ts` file using NextAuth's `withAuth` wrapper — unauthenticated requests are redirected to `/auth/signin`
- **Public routes:** `/auth/signin` only

### Required environment variables (`.env.local`)

```
NEXTAUTH_SECRET=
NEXTAUTH_URL=http://localhost:3000        # required for OAuth callback URL construction
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
BIGTABLE_PROJECT_ID=
BIGTABLE_INSTANCE_ID=
```

---

## Data Layer

### BigTable schema (existing)

- **Table:** `telemetry`
- **Row key:** `{deviceId}#{ISO8601_timestamp}`
- **Column families:** `static` (unchanging attributes), `dynamic` (time-series readings)
- **Example qualifiers:** `dynamic:battery.temp`, `dynamic:battery.soc`, `static:index`

### API routes

#### `GET /api/devices`

Fleet overview data.

1. Performs a key-only scan of the BigTable table using a `StripValueTransformer` filter (reads row keys, discards all cell values)
2. Extracts unique device IDs from the `{deviceId}#{timestamp}` row key format
3. For each unique device ID, fetches the single latest row using a reversed scan within the device's key prefix (`{deviceId}#` → `{deviceId}$`, descending) and takes the first result — this yields the most recent timestamp
4. Returns: `{ devices: Array<{ deviceId: string, lastSeen: string, columns: Record<string, string> }> }`

Columns in the response are whatever qualifiers are present in each device's latest row — fully dynamic, no hardcoding.

**Scaling note:** Key scan is O(total rows). Acceptable at pilot scale. When the fleet grows, a separate `device-index` BigTable table (one row per known device ID, populated by writers on first publish) eliminates the scan entirely.

#### `GET /api/devices/[id]?range=1h`

Per-device time-series data.

- Queries BigTable for all rows with the device ID prefix within the requested time range
- `range` values: `1h` (default), `6h`, `24h`, `7d`
- The range is translated to BigTable row-key bounds: compute `startTime = now - duration`, then scan rows from `{deviceId}#{startTime.toISOString()}` to `{deviceId}#{now.toISOString()}` (inclusive). The `#` separator is part of the key and must be included in the bounds to avoid matching other device prefixes.
- Returns: `{ deviceId: string, columns: string[], rows: Array<{ timestamp: string, values: Record<string, string> }> }`
- Column list is the union of all qualifiers seen across returned rows

**Column display:** The `family:qualifier` format (e.g. `dynamic:battery.temp`) is used internally; the family prefix is stripped for display (shown as `battery.temp`).

---

## Pages & Routing

```
/                        Redirects to /fleet
/fleet                   Fleet overview
/device/[id]             Device detail (time-series)
/api/devices             Protected API route
/api/devices/[id]        Protected API route
/auth/signin             NextAuth sign-in page (public)
```

### Shared layout

Sidebar navigation on the left, content area on the right.

Sidebar contains:
- App name / logo
- "Fleet" nav link
- User avatar and email (bottom)
- Sign-out button

### Fleet page (`/fleet`)

- Heading: "Fleet" with device count
- Table: one row per device
  - Fixed columns: Device ID, Last Seen
  - Dynamic columns: one per discovered data key, family prefix stripped
- Rows are clickable; clicking navigates to `/device/[id]`

### Device detail page (`/device/[id]`)

- Breadcrumb: Fleet › `{deviceId}`
- Heading: device ID
- Time range selector: 1h | 6h | 24h | 7d (default: 1h)
- Table: Timestamp + one column per data key
- Data re-fetches when time range changes

---

## Future Increments

- **GPS/Maps:** Detect known GPS qualifier names (e.g. `dynamic:gps.lat` / `dynamic:gps.lon`) in the column set and render a Google Maps panel alongside the table on the device detail page
- **Auto-refresh:** Polling interval on the fleet overview
- **Device index table:** Eliminate the fleet scan at scale (see scaling note above)
- **GKE deployment:** Swap ADC for Workload Identity — no code changes required
