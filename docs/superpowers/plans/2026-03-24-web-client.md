# Nexus SDV Web Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Next.js web dashboard at `sample-clients/data-web-client` that shows BigTable telemetry in a fleet overview with per-device drill-down, secured via Google Workspace OAuth.

**Architecture:** Standalone Next.js App Router app. API routes are a thin BFF querying BigTable directly via the Node.js SDK with ADC. Client components fetch from `/api/*`. Middleware protects UI pages; API routes check session explicitly. No UI component has a direct BigTable dependency.

**Tech Stack:** Next.js 14+ (App Router, TypeScript), next-auth v4, @google-cloud/bigtable, @tanstack/react-table, Tailwind CSS, Jest + React Testing Library.

---

## File Structure

```
sample-clients/data-web-client/
├── .env.local.example
├── jest.config.ts
├── jest.setup.ts
├── middleware.ts                              # NextAuth withAuth — protects UI pages
├── src/
│   ├── app/
│   │   ├── layout.tsx                        # Root: wraps app in SessionProvider
│   │   ├── session-provider.tsx              # 'use client' wrapper for NextAuth SessionProvider
│   │   ├── page.tsx                          # Redirects / → /fleet
│   │   ├── auth/signin/page.tsx              # Google sign-in button (public)
│   │   ├── fleet/page.tsx                    # Fleet overview (client component)
│   │   ├── device/[id]/page.tsx              # Device detail (client component)
│   │   └── api/
│   │       ├── auth/[...nextauth]/route.ts   # NextAuth handler
│   │       ├── devices/route.ts              # GET /api/devices
│   │       └── devices/[id]/route.ts         # GET /api/devices/[id]
│   ├── components/
│   │   ├── app-layout.tsx                    # Sidebar + content wrapper
│   │   ├── sidebar.tsx                       # Nav, user, sign-out (client component)
│   │   ├── data-table.tsx                    # TanStack Table, dynamic columns (client component)
│   │   └── time-range-selector.tsx           # 1h/6h/24h/7d selector (client component)
│   ├── lib/
│   │   ├── auth.ts                           # NextAuth options (shared by route + API routes)
│   │   ├── bigtable.ts                       # BigTable client singleton
│   │   ├── devices.ts                        # getDevices() — fleet query
│   │   └── device-detail.ts                  # getDeviceTimeSeries() — time-series query
│   └── types/
│       └── telemetry.ts                      # Shared TypeScript types
└── __tests__/
    ├── lib/
    │   ├── bigtable.test.ts
    │   ├── devices.test.ts
    │   └── device-detail.test.ts
    ├── api/
    │   ├── devices.test.ts
    │   └── devices-id.test.ts
    └── components/
        ├── data-table.test.tsx
        └── time-range-selector.test.tsx
```

---

## Task 1: Project scaffold

**Files:**
- Create: `sample-clients/data-web-client/` (via create-next-app)
- Create: `sample-clients/data-web-client/.env.local.example`
- Create: `sample-clients/data-web-client/jest.config.ts`
- Create: `sample-clients/data-web-client/jest.setup.ts`

- [ ] **Step 1: Scaffold with create-next-app**

From the repo root:

```bash
cd sample-clients
npx create-next-app@latest data-web-client \
  --typescript \
  --tailwind \
  --eslint \
  --app \
  --src-dir \
  --import-alias "@/*" \
  --no-turbopack
cd data-web-client
```

Accept all defaults when prompted.

- [ ] **Step 2: Install runtime dependencies**

```bash
npm install next-auth @google-cloud/bigtable @tanstack/react-table
```

- [ ] **Step 3: Install test dependencies**

```bash
npm install --save-dev jest jest-environment-jsdom @testing-library/react @testing-library/jest-dom @testing-library/user-event @types/jest
```

- [ ] **Step 4: Create jest.config.ts**

```typescript
// jest.config.ts
import type { Config } from 'jest';
import nextJest from 'next/jest.js';

const createJestConfig = nextJest({ dir: './' });

const config: Config = {
  coverageProvider: 'v8',
  testEnvironment: 'jsdom',
  setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',
  },
};

export default createJestConfig(config);
```

- [ ] **Step 5: Create jest.setup.ts**

```typescript
// jest.setup.ts
import '@testing-library/jest-dom';
```

- [ ] **Step 6: Create .env.local.example**

```bash
# .env.local.example
NEXTAUTH_SECRET=generate-with-openssl-rand-base64-32
NEXTAUTH_URL=http://localhost:3000
GOOGLE_CLIENT_ID=your-gcp-oauth-client-id
GOOGLE_CLIENT_SECRET=your-gcp-oauth-client-secret
BIGTABLE_PROJECT_ID=your-gcp-project-id
BIGTABLE_INSTANCE_ID=bigtable-production-storage
```

- [ ] **Step 7: Verify tests run (no tests yet — just confirm the runner works)**

```bash
npm test -- --passWithNoTests
```

Expected: `Test Suites: 0 passed`

- [ ] **Step 8: Commit**

```bash
git add sample-clients/data-web-client
git commit -m "feat(web-client): scaffold Next.js project with TypeScript, Tailwind, Jest"
```

---

## Task 2: Types and BigTable client

**Files:**
- Create: `src/types/telemetry.ts`
- Create: `src/lib/bigtable.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// __tests__/lib/bigtable.test.ts
import { getTelemetryTable } from '@/lib/bigtable';

describe('getTelemetryTable', () => {
  it('returns a Table object with the telemetry table name', () => {
    process.env.BIGTABLE_PROJECT_ID = 'test-project';
    process.env.BIGTABLE_INSTANCE_ID = 'test-instance';

    const table = getTelemetryTable();

    // The SDK Table object exposes its name as a string
    expect(table.name).toContain('telemetry');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
npm test -- --testPathPattern="bigtable" --no-coverage
```

Expected: FAIL — `Cannot find module '@/lib/bigtable'`

- [ ] **Step 3: Create types**

```typescript
// src/types/telemetry.ts
export interface DeviceRow {
  deviceId: string;
  lastSeen: string;
  columns: Record<string, string>;
}

export interface DevicesResponse {
  devices: DeviceRow[];
}

export interface TimeSeriesRow {
  timestamp: string;
  values: Record<string, string>;
}

export interface DeviceDetailResponse {
  deviceId: string;
  columns: string[];
  rows: TimeSeriesRow[];
}

export type TimeRange = '1h' | '6h' | '24h' | '7d';

export const TIME_RANGE_MS: Record<TimeRange, number> = {
  '1h': 60 * 60 * 1000,
  '6h': 6 * 60 * 60 * 1000,
  '24h': 24 * 60 * 60 * 1000,
  '7d': 7 * 24 * 60 * 60 * 1000,
};
```

- [ ] **Step 4: Create BigTable client singleton**

```typescript
// src/lib/bigtable.ts
import { Bigtable } from '@google-cloud/bigtable';

let _client: Bigtable | null = null;

function getClient(): Bigtable {
  if (!_client) {
    _client = new Bigtable({ projectId: process.env.BIGTABLE_PROJECT_ID });
  }
  return _client;
}

export function getTelemetryTable() {
  const instance = getClient().instance(process.env.BIGTABLE_INSTANCE_ID!);
  return instance.table('telemetry');
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
npm test -- --testPathPattern="bigtable" --no-coverage
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/types/telemetry.ts src/lib/bigtable.ts __tests__/lib/bigtable.test.ts
git commit -m "feat(web-client): add types and BigTable client singleton"
```

---

## Task 3: Fleet query lib — `getDevices()`

**Files:**
- Create: `src/lib/devices.ts`
- Test: `__tests__/lib/devices.test.ts`

The BigTable row key format is `{deviceId}#{ISO8601_timestamp}`. `getDevices()` does two passes:
1. A key-only scan using a `StripValueTransformer` filter (reads keys, discards cell values).
2. For each unique device ID, a reversed scan in the key range `[{deviceId}#, {deviceId}$)` with `limit: 1` — returns the row with the highest (latest) timestamp first.

Cell values in the SDK come back as `row.data[family][qualifier][0].value` (a `Buffer`).

- [ ] **Step 1: Write failing tests**

```typescript
// __tests__/lib/devices.test.ts
import { Readable } from 'stream';
import { getDevices } from '@/lib/devices';
import { getTelemetryTable } from '@/lib/bigtable';

jest.mock('@/lib/bigtable');

function makeStream(rows: { id: string }[]) {
  return Readable.from(rows, { objectMode: true });
}

describe('getDevices', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns empty array when table is empty', async () => {
    const mockTable = {
      createReadStream: jest.fn().mockReturnValue(makeStream([])),
      getRows: jest.fn(),
    };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDevices();

    expect(result).toEqual([]);
    expect(mockTable.getRows).not.toHaveBeenCalled();
  });

  it('returns one entry per unique device with latest row data', async () => {
    const keyRows = [
      { id: 'dev-001#2024-01-01T00:00:00.000Z' },
      { id: 'dev-001#2024-01-01T00:01:00.000Z' },
      { id: 'dev-002#2024-01-01T00:00:30.000Z' },
    ];

    const latestDev1 = {
      id: 'dev-001#2024-01-01T00:01:00.000Z',
      data: {
        dynamic: {
          'battery.temp': [{ value: Buffer.from('25.0') }],
        },
      },
    };
    const latestDev2 = {
      id: 'dev-002#2024-01-01T00:00:30.000Z',
      data: {
        static: { index: [{ value: Buffer.from('7') }] },
      },
    };

    const mockTable = {
      createReadStream: jest.fn().mockReturnValue(makeStream(keyRows)),
      getRows: jest.fn()
        .mockResolvedValueOnce([[latestDev1]])
        .mockResolvedValueOnce([[latestDev2]]),
    };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDevices();

    expect(result).toHaveLength(2);

    const dev1 = result.find(d => d.deviceId === 'dev-001')!;
    expect(dev1.lastSeen).toBe('2024-01-01T00:01:00.000Z');
    expect(dev1.columns).toEqual({ 'dynamic:battery.temp': '25.0' });

    const dev2 = result.find(d => d.deviceId === 'dev-002')!;
    expect(dev2.columns).toEqual({ 'static:index': '7' });
  });

  it('calls getRows with reversed:true and limit:1 per device', async () => {
    const keyRows = [{ id: 'dev-001#2024-01-01T00:00:00.000Z' }];
    const latestRow = {
      id: 'dev-001#2024-01-01T00:00:00.000Z',
      data: { dynamic: { temp: [{ value: Buffer.from('20') }] } },
    };

    const mockTable = {
      createReadStream: jest.fn().mockReturnValue(makeStream(keyRows)),
      getRows: jest.fn().mockResolvedValueOnce([[latestRow]]),
    };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    await getDevices();

    expect(mockTable.getRows).toHaveBeenCalledWith(
      expect.objectContaining({ reversed: true, limit: 1 })
    );
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="devices.test" --no-coverage
```

Expected: FAIL — `Cannot find module '@/lib/devices'`

- [ ] **Step 3: Implement getDevices()**

```typescript
// src/lib/devices.ts
import { getTelemetryTable } from './bigtable';
import type { DeviceRow } from '@/types/telemetry';

export async function getDevices(): Promise<DeviceRow[]> {
  const table = getTelemetryTable();

  // Pass 1: key-only scan to discover unique device IDs
  // StripValueTransformer filter reads keys and discards all cell values.
  // Verify the exact filter option against the @google-cloud/bigtable SDK docs
  // if the behaviour is unexpected — the intent is strip:true in a filter array.
  const deviceIds = await new Promise<Set<string>>((resolve, reject) => {
    const ids = new Set<string>();
    const stream = table.createReadStream({ filter: [{ strip: true }] });
    stream.on('data', (row: { id: string }) => {
      const sep = row.id.indexOf('#');
      if (sep > 0) ids.add(row.id.slice(0, sep));
    });
    stream.on('error', reject);
    stream.on('end', () => resolve(ids));
  });

  // Pass 2: reversed scan per device — first result = latest row
  // Range [{deviceId}#, {deviceId}$) covers all timestamps for that device.
  // '$' (ASCII 36) > '#' (ASCII 35), so this range is tight and won't bleed into other devices.
  const devices: DeviceRow[] = [];

  for (const deviceId of deviceIds) {
    const [rows] = await table.getRows({
      ranges: [{ start: `${deviceId}#`, end: `${deviceId}$` }],
      limit: 1,
      reversed: true,
    });

    if (!rows?.length) continue;

    const row = rows[0];
    const sep = row.id.indexOf('#');
    const lastSeen = sep > 0 ? row.id.slice(sep + 1) : '';
    const columns: Record<string, string> = {};

    for (const [family, qualifiers] of Object.entries(
      (row.data ?? {}) as Record<string, Record<string, Array<{ value: Buffer }>>>
    )) {
      for (const [qualifier, cells] of Object.entries(qualifiers)) {
        columns[`${family}:${qualifier}`] = cells[0].value.toString();
      }
    }

    devices.push({ deviceId, lastSeen, columns });
  }

  return devices;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="devices.test" --no-coverage
```

Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/lib/devices.ts __tests__/lib/devices.test.ts
git commit -m "feat(web-client): implement getDevices() with key scan and reversed lookup"
```

---

## Task 4: Device time-series query — `getDeviceTimeSeries()`

**Files:**
- Create: `src/lib/device-detail.ts`
- Test: `__tests__/lib/device-detail.test.ts`

Row-key bounds: `{deviceId}#{startTime.toISOString()}` → `{deviceId}#{now.toISOString()}`. The `#` separator is part of the key and must be included to avoid matching keys from other devices that share a common prefix.

- [ ] **Step 1: Write failing tests**

```typescript
// __tests__/lib/device-detail.test.ts
import { getDeviceTimeSeries } from '@/lib/device-detail';
import { getTelemetryTable } from '@/lib/bigtable';

jest.mock('@/lib/bigtable');

describe('getDeviceTimeSeries', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns empty rows and columns when no data found', async () => {
    const mockTable = { getRows: jest.fn().mockResolvedValue([[]]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDeviceTimeSeries('dev-001', '1h');

    expect(result).toEqual({ deviceId: 'dev-001', columns: [], rows: [] });
  });

  it('extracts rows and unions column names across all rows', async () => {
    const mockRows = [
      {
        id: 'dev-001#2024-01-01T00:00:00.000Z',
        data: { dynamic: { temp: [{ value: Buffer.from('25.0') }] } },
      },
      {
        id: 'dev-001#2024-01-01T00:01:00.000Z',
        data: {
          dynamic: {
            temp: [{ value: Buffer.from('26.0') }],
            soc: [{ value: Buffer.from('85') }],
          },
        },
      },
    ];
    const mockTable = { getRows: jest.fn().mockResolvedValue([mockRows]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const result = await getDeviceTimeSeries('dev-001', '1h');

    expect(result.deviceId).toBe('dev-001');
    expect(result.columns).toContain('dynamic:temp');
    expect(result.columns).toContain('dynamic:soc');
    expect(result.rows).toHaveLength(2);
    expect(result.rows[0].values['dynamic:temp']).toBe('25.0');
    expect(result.rows[1].values['dynamic:soc']).toBe('85');
  });

  it('constructs row-key bounds correctly including the # separator', async () => {
    const mockTable = { getRows: jest.fn().mockResolvedValue([[]]) };
    (getTelemetryTable as jest.Mock).mockReturnValue(mockTable);

    const before = new Date();
    await getDeviceTimeSeries('dev-001', '1h');
    const after = new Date();

    const callArgs = mockTable.getRows.mock.calls[0][0];
    const range = callArgs.ranges[0];

    expect(range.start).toMatch(/^dev-001#/);
    expect(range.end).toMatch(/^dev-001#/);

    const startTs = new Date(range.start.slice('dev-001#'.length));
    const endTs = new Date(range.end.slice('dev-001#'.length));

    // start should be ~1h before now
    expect(before.getTime() - startTs.getTime()).toBeGreaterThanOrEqual(60 * 60 * 1000 - 1000);
    expect(before.getTime() - startTs.getTime()).toBeLessThanOrEqual(60 * 60 * 1000 + 1000);

    // end should be approximately now
    expect(endTs.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(endTs.getTime()).toBeLessThanOrEqual(after.getTime());
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="device-detail.test" --no-coverage
```

Expected: FAIL — `Cannot find module '@/lib/device-detail'`

- [ ] **Step 3: Implement getDeviceTimeSeries()**

```typescript
// src/lib/device-detail.ts
import { getTelemetryTable } from './bigtable';
import type { DeviceDetailResponse, TimeRange } from '@/types/telemetry';
import { TIME_RANGE_MS } from '@/types/telemetry';

export async function getDeviceTimeSeries(
  deviceId: string,
  range: TimeRange = '1h',
): Promise<DeviceDetailResponse> {
  const table = getTelemetryTable();

  const now = new Date();
  const startTime = new Date(now.getTime() - TIME_RANGE_MS[range]);

  // Row key bounds include the '#' separator so we don't bleed into adjacent device keys
  const startKey = `${deviceId}#${startTime.toISOString()}`;
  const endKey = `${deviceId}#${now.toISOString()}`;

  const [rows] = await table.getRows({
    ranges: [{ start: startKey, end: endKey }],
  });

  const columnSet = new Set<string>();

  const resultRows = (rows ?? []).map((row) => {
    const sep = row.id.indexOf('#');
    const timestamp = sep > 0 ? row.id.slice(sep + 1) : row.id;
    const values: Record<string, string> = {};

    for (const [family, qualifiers] of Object.entries(
      (row.data ?? {}) as Record<string, Record<string, Array<{ value: Buffer }>>>
    )) {
      for (const [qualifier, cells] of Object.entries(qualifiers)) {
        const key = `${family}:${qualifier}`;
        columnSet.add(key);
        values[key] = cells[0].value.toString();
      }
    }

    return { timestamp, values };
  });

  return { deviceId, columns: Array.from(columnSet), rows: resultRows };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="device-detail.test" --no-coverage
```

Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/lib/device-detail.ts __tests__/lib/device-detail.test.ts
git commit -m "feat(web-client): implement getDeviceTimeSeries() with row-key bound scan"
```

---

## Task 5: NextAuth setup

**Files:**
- Create: `src/lib/auth.ts`
- Create: `src/app/api/auth/[...nextauth]/route.ts`
- Create: `middleware.ts`
- Create: `src/app/session-provider.tsx`
- Create: `src/app/auth/signin/page.tsx`

No unit tests for this task — NextAuth internals are well-tested by the library. Manual verification in Task 10.

- [ ] **Step 1: Create NextAuth options**

```typescript
// src/lib/auth.ts
import type { NextAuthOptions } from 'next-auth';
import GoogleProvider from 'next-auth/providers/google';

export const authOptions: NextAuthOptions = {
  providers: [
    GoogleProvider({
      clientId: process.env.GOOGLE_CLIENT_ID!,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET!,
    }),
  ],
  pages: {
    signIn: '/auth/signin',
  },
};
```

- [ ] **Step 2: Create NextAuth route handler**

```typescript
// src/app/api/auth/[...nextauth]/route.ts
import NextAuth from 'next-auth';
import { authOptions } from '@/lib/auth';

const handler = NextAuth(authOptions);

export { handler as GET, handler as POST };
```

- [ ] **Step 3: Create middleware**

The matcher covers UI pages only. API routes check session explicitly.

```typescript
// middleware.ts
export { default } from 'next-auth/middleware';

export const config = {
  matcher: ['/fleet/:path*', '/device/:path*'],
};
```

- [ ] **Step 4: Create SessionProvider client wrapper**

NextAuth's `SessionProvider` is a client component. Next.js App Router requires a `'use client'` wrapper to use it in the server-rendered root layout.

```tsx
// src/app/session-provider.tsx
'use client';
import { SessionProvider as NextAuthSessionProvider } from 'next-auth/react';

export function SessionProvider({ children }: { children: React.ReactNode }) {
  return <NextAuthSessionProvider>{children}</NextAuthSessionProvider>;
}
```

- [ ] **Step 5: Update root layout to wrap children in SessionProvider**

Edit the auto-generated `src/app/layout.tsx`. Add the import and wrap `{children}`:

```tsx
// src/app/layout.tsx
import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';
import { SessionProvider } from './session-provider';

const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = { title: 'Nexus SDV' };

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className={inter.className}>
        <SessionProvider>{children}</SessionProvider>
      </body>
    </html>
  );
}
```

- [ ] **Step 6: Create sign-in page**

```tsx
// src/app/auth/signin/page.tsx
'use client';
import { signIn } from 'next-auth/react';

export default function SignInPage() {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50">
      <div className="text-center space-y-4">
        <h1 className="text-2xl font-bold text-gray-900">Nexus SDV</h1>
        <p className="text-gray-500">Sign in to access the dashboard</p>
        <button
          onClick={() => signIn('google', { callbackUrl: '/fleet' })}
          className="px-6 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
        >
          Sign in with Google
        </button>
      </div>
    </div>
  );
}
```

- [ ] **Step 7: Create root redirect**

```tsx
// src/app/page.tsx
import { redirect } from 'next/navigation';

export default function HomePage() {
  redirect('/fleet');
}
```

- [ ] **Step 8: Commit**

```bash
git add src/lib/auth.ts src/app/api/auth src/app/session-provider.tsx \
        src/app/auth src/app/layout.tsx src/app/page.tsx middleware.ts
git commit -m "feat(web-client): add NextAuth with Google OAuth and middleware protection"
```

---

## Task 6: API routes

**Files:**
- Create: `src/app/api/devices/route.ts`
- Create: `src/app/api/devices/[id]/route.ts`
- Test: `__tests__/api/devices.test.ts`
- Test: `__tests__/api/devices-id.test.ts`

Both routes: check session with `getServerSession(authOptions)`, return `401` if missing.

**Note on testing App Router route handlers:** Import the handler function directly and call it with a `Request` object. Mock `next-auth` and the lib modules.

- [ ] **Step 1: Write failing tests for GET /api/devices**

```typescript
// __tests__/api/devices.test.ts
import { GET } from '@/app/api/devices/route';
import { getServerSession } from 'next-auth';
import { getDevices } from '@/lib/devices';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/devices');

describe('GET /api/devices', () => {
  it('returns 401 when not authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(null);

    const res = await GET();

    expect(res.status).toBe(401);
  });

  it('returns device list when authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDevices as jest.Mock).mockResolvedValue([
      { deviceId: 'dev-001', lastSeen: '2024-01-01T00:00:00Z', columns: {} },
    ]);

    const res = await GET();
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.devices).toHaveLength(1);
    expect(body.devices[0].deviceId).toBe('dev-001');
  });
});
```

- [ ] **Step 2: Write failing tests for GET /api/devices/[id]**

```typescript
// __tests__/api/devices-id.test.ts
import { GET } from '@/app/api/devices/[id]/route';
import { getServerSession } from 'next-auth';
import { getDeviceTimeSeries } from '@/lib/device-detail';

jest.mock('next-auth', () => ({ getServerSession: jest.fn() }));
jest.mock('@/lib/device-detail');

function makeRequest(id: string, range?: string) {
  const url = `http://localhost/api/devices/${id}${range ? `?range=${range}` : ''}`;
  return { url } as Request;
}

describe('GET /api/devices/[id]', () => {
  it('returns 401 when not authenticated', async () => {
    (getServerSession as jest.Mock).mockResolvedValue(null);

    const res = await GET(makeRequest('dev-001'), { params: { id: 'dev-001' } });

    expect(res.status).toBe(401);
  });

  it('returns time-series data with default range 1h', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: ['dynamic:temp'], rows: [],
    });

    const res = await GET(makeRequest('dev-001'), { params: { id: 'dev-001' } });
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.deviceId).toBe('dev-001');
    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h');
  });

  it('passes valid range param through', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: [], rows: [],
    });

    await GET(makeRequest('dev-001', '7d'), { params: { id: 'dev-001' } });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '7d');
  });

  it('defaults to 1h for invalid range values', async () => {
    (getServerSession as jest.Mock).mockResolvedValue({ user: { email: 'a@test.com' } });
    (getDeviceTimeSeries as jest.Mock).mockResolvedValue({
      deviceId: 'dev-001', columns: [], rows: [],
    });

    await GET(makeRequest('dev-001', 'invalid'), { params: { id: 'dev-001' } });

    expect(getDeviceTimeSeries).toHaveBeenCalledWith('dev-001', '1h');
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="__tests__/api" --no-coverage
```

Expected: FAIL — modules not found

- [ ] **Step 4: Implement GET /api/devices**

```typescript
// src/app/api/devices/route.ts
import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getDevices } from '@/lib/devices';

export async function GET() {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const devices = await getDevices();
  return NextResponse.json({ devices });
}
```

- [ ] **Step 5: Implement GET /api/devices/[id]**

```typescript
// src/app/api/devices/[id]/route.ts
import { NextResponse } from 'next/server';
import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getDeviceTimeSeries } from '@/lib/device-detail';
import type { TimeRange } from '@/types/telemetry';

const VALID_RANGES = new Set<TimeRange>(['1h', '6h', '24h', '7d']);

function parseRange(value: string | null): TimeRange {
  if (value && VALID_RANGES.has(value as TimeRange)) return value as TimeRange;
  return '1h';
}

export async function GET(
  request: Request,
  { params }: { params: { id: string } },
) {
  const session = await getServerSession(authOptions);
  if (!session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const { searchParams } = new URL(request.url);
  const range = parseRange(searchParams.get('range'));

  const data = await getDeviceTimeSeries(params.id, range);
  return NextResponse.json(data);
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="__tests__/api" --no-coverage
```

Expected: PASS (7 tests)

- [ ] **Step 7: Commit**

```bash
git add src/app/api/devices __tests__/api
git commit -m "feat(web-client): add protected API routes for fleet and device detail"
```

---

## Task 7: Shared layout — sidebar and app-layout

**Files:**
- Create: `src/components/app-layout.tsx`
- Create: `src/components/sidebar.tsx`

No unit tests for layout components — they are thin wrappers. Verified visually in Task 9.

- [ ] **Step 1: Create AppLayout**

```tsx
// src/components/app-layout.tsx
import Sidebar from './sidebar';

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen bg-white">
      <Sidebar />
      <main className="flex-1 overflow-auto p-6">{children}</main>
    </div>
  );
}
```

- [ ] **Step 2: Create Sidebar**

```tsx
// src/components/sidebar.tsx
'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useSession, signOut } from 'next-auth/react';

export default function Sidebar() {
  const pathname = usePathname();
  const { data: session } = useSession();

  const fleetActive =
    pathname === '/fleet' || pathname.startsWith('/device');

  return (
    <aside className="w-56 flex flex-col bg-gray-900 text-white shrink-0">
      <div className="px-4 py-5 text-lg font-semibold tracking-tight border-b border-gray-700">
        Nexus SDV
      </div>

      <nav className="flex-1 px-2 py-4">
        <Link
          href="/fleet"
          className={`flex items-center px-3 py-2 rounded text-sm ${
            fleetActive
              ? 'bg-gray-700 text-white'
              : 'text-gray-400 hover:bg-gray-800 hover:text-white'
          }`}
        >
          Fleet
        </Link>
      </nav>

      <div className="px-4 py-4 border-t border-gray-700 text-sm">
        <p className="text-gray-400 truncate mb-2">{session?.user?.email}</p>
        <button
          onClick={() => signOut({ callbackUrl: '/auth/signin' })}
          className="text-gray-500 hover:text-white"
        >
          Sign out
        </button>
      </div>
    </aside>
  );
}
```

- [ ] **Step 3: Commit**

```bash
git add src/components/app-layout.tsx src/components/sidebar.tsx
git commit -m "feat(web-client): add sidebar and shared app layout"
```

---

## Task 8: DataTable component

**Files:**
- Create: `src/components/data-table.tsx`
- Test: `__tests__/components/data-table.test.tsx`

The table accepts `columnKeys: string[]` (internal keys like `dynamic:battery.temp`), a `displayHeader` function to strip the family prefix, and `data: Record<string, string>[]`. An optional `onRowClick` handler enables navigation.

- [ ] **Step 1: Write failing tests**

```tsx
// __tests__/components/data-table.test.tsx
import { render, screen, fireEvent } from '@testing-library/react';
import DataTable from '@/components/data-table';

const testColumns = ['dynamic:temp', 'static:id'];
const testData = [
  { 'dynamic:temp': '25.0', 'static:id': 'abc' },
  { 'dynamic:temp': '26.0', 'static:id': 'def' },
];

describe('DataTable', () => {
  it('renders column headers with family prefix stripped', () => {
    render(<DataTable columnKeys={testColumns} data={testData} />);

    expect(screen.getByText('temp')).toBeInTheDocument();
    expect(screen.getByText('id')).toBeInTheDocument();
    expect(screen.queryByText('dynamic:temp')).not.toBeInTheDocument();
  });

  it('renders all data rows', () => {
    render(<DataTable columnKeys={testColumns} data={testData} />);

    expect(screen.getByText('25.0')).toBeInTheDocument();
    expect(screen.getByText('26.0')).toBeInTheDocument();
  });

  it('calls onRowClick with row data when row is clicked', () => {
    const onRowClick = jest.fn();
    render(<DataTable columnKeys={testColumns} data={testData} onRowClick={onRowClick} />);

    fireEvent.click(screen.getByText('25.0').closest('tr')!);

    expect(onRowClick).toHaveBeenCalledWith(testData[0]);
  });

  it('renders "—" for missing values', () => {
    const sparseData = [{ 'dynamic:temp': '25.0' }];
    render(<DataTable columnKeys={testColumns} data={sparseData} />);

    expect(screen.getByText('—')).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="data-table" --no-coverage
```

Expected: FAIL — `Cannot find module '@/components/data-table'`

- [ ] **Step 3: Implement DataTable**

```tsx
// src/components/data-table.tsx
'use client';
import {
  useReactTable,
  getCoreRowModel,
  flexRender,
  createColumnHelper,
} from '@tanstack/react-table';

interface DataTableProps {
  columnKeys: string[];
  data: Record<string, string>[];
  onRowClick?: (row: Record<string, string>) => void;
}

function stripFamily(key: string): string {
  const colon = key.indexOf(':');
  return colon > -1 ? key.slice(colon + 1) : key;
}

const columnHelper = createColumnHelper<Record<string, string>>();

export default function DataTable({ columnKeys, data, onRowClick }: DataTableProps) {
  const columns = columnKeys.map((key) =>
    columnHelper.accessor((row) => row[key] ?? '—', {
      id: key,
      header: stripFamily(key),
    })
  );

  const table = useReactTable({
    data,
    columns,
    getCoreRowModel: getCoreRowModel(),
  });

  return (
    <div className="overflow-x-auto rounded border border-gray-200">
      <table className="w-full text-sm">
        <thead className="bg-gray-50">
          {table.getHeaderGroups().map((headerGroup) => (
            <tr key={headerGroup.id}>
              {headerGroup.headers.map((header) => (
                <th
                  key={header.id}
                  className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider"
                >
                  {flexRender(header.column.columnDef.header, header.getContext())}
                </th>
              ))}
            </tr>
          ))}
        </thead>
        <tbody className="divide-y divide-gray-100">
          {table.getRowModel().rows.map((row) => (
            <tr
              key={row.id}
              onClick={() => onRowClick?.(row.original)}
              className={onRowClick ? 'cursor-pointer hover:bg-gray-50' : ''}
            >
              {row.getVisibleCells().map((cell) => (
                <td key={cell.id} className="px-4 py-2 text-gray-700">
                  {flexRender(cell.column.columnDef.cell, cell.getContext())}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="data-table" --no-coverage
```

Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add src/components/data-table.tsx __tests__/components/data-table.test.tsx
git commit -m "feat(web-client): add dynamic DataTable component with TanStack Table"
```

---

## Task 9: Fleet overview page

**Files:**
- Create: `src/app/fleet/page.tsx`

The fleet page is a client component that fetches from `/api/devices` on mount and builds dynamic columns from the union of all device column keys.

- [ ] **Step 1: Implement the fleet page**

```tsx
// src/app/fleet/page.tsx
'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import AppLayout from '@/components/app-layout';
import DataTable from '@/components/data-table';
import type { DevicesResponse, DeviceRow } from '@/types/telemetry';

function formatLastSeen(iso: string): string {
  if (!iso) return '—';
  const diff = Date.now() - new Date(iso).getTime();
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  return new Date(iso).toLocaleString();
}

export default function FleetPage() {
  const router = useRouter();
  const [devices, setDevices] = useState<DeviceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch('/api/devices')
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<DevicesResponse>;
      })
      .then((data) => {
        setDevices(data.devices);
        setLoading(false);
      })
      .catch((e: Error) => {
        setError(e.message);
        setLoading(false);
      });
  }, []);

  // Build flat rows and column key list for the table
  const allColumnKeys = Array.from(
    new Set(devices.flatMap((d) => Object.keys(d.columns)))
  ).sort();

  const tableColumnKeys = ['deviceId', 'lastSeen', ...allColumnKeys];

  const tableData = devices.map((d) => ({
    deviceId: d.deviceId,
    lastSeen: formatLastSeen(d.lastSeen),
    ...d.columns,
  }));

  return (
    <AppLayout>
      <div className="space-y-4">
        <h1 className="text-xl font-semibold text-gray-900">
          Fleet{!loading && ` · ${devices.length} devices`}
        </h1>

        {loading && <p className="text-gray-500">Loading...</p>}
        {error && <p className="text-red-500">Error: {error}</p>}
        {!loading && !error && (
          <DataTable
            columnKeys={tableColumnKeys}
            data={tableData}
            onRowClick={(row) => router.push(`/device/${row.deviceId}`)}
          />
        )}
      </div>
    </AppLayout>
  );
}
```

- [ ] **Step 2: Start the dev server and verify the fleet page renders**

First, copy the example env file and fill in your values:
```bash
cp .env.local.example .env.local
# Edit .env.local with your actual GCP and Google OAuth credentials
```

Then:
```bash
npm run dev
```

Navigate to `http://localhost:3000`. Expect redirect to `/auth/signin`, then after Google login, redirect to `/fleet`. The table should show your devices.

- [ ] **Step 3: Commit**

```bash
git add src/app/fleet/page.tsx
git commit -m "feat(web-client): add fleet overview page with dynamic column table"
```

---

## Task 10: Device detail page

**Files:**
- Create: `src/components/time-range-selector.tsx`
- Create: `src/app/device/[id]/page.tsx`
- Test: `__tests__/components/time-range-selector.test.tsx`

- [ ] **Step 1: Write failing tests for TimeRangeSelector**

```tsx
// __tests__/components/time-range-selector.test.tsx
import { render, screen, fireEvent } from '@testing-library/react';
import TimeRangeSelector from '@/components/time-range-selector';

describe('TimeRangeSelector', () => {
  it('renders all four range options', () => {
    render(<TimeRangeSelector value="1h" onChange={jest.fn()} />);

    expect(screen.getByText('1h')).toBeInTheDocument();
    expect(screen.getByText('6h')).toBeInTheDocument();
    expect(screen.getByText('24h')).toBeInTheDocument();
    expect(screen.getByText('7d')).toBeInTheDocument();
  });

  it('highlights the active range', () => {
    render(<TimeRangeSelector value="6h" onChange={jest.fn()} />);

    const active = screen.getByText('6h');
    expect(active).toHaveClass('bg-blue-600');

    const inactive = screen.getByText('1h');
    expect(inactive).not.toHaveClass('bg-blue-600');
  });

  it('calls onChange with selected range when a button is clicked', () => {
    const onChange = jest.fn();
    render(<TimeRangeSelector value="1h" onChange={onChange} />);

    fireEvent.click(screen.getByText('24h'));

    expect(onChange).toHaveBeenCalledWith('24h');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="time-range-selector" --no-coverage
```

Expected: FAIL

- [ ] **Step 3: Implement TimeRangeSelector**

```tsx
// src/components/time-range-selector.tsx
'use client';
import type { TimeRange } from '@/types/telemetry';

const RANGES: TimeRange[] = ['1h', '6h', '24h', '7d'];

interface TimeRangeSelectorProps {
  value: TimeRange;
  onChange: (range: TimeRange) => void;
}

export default function TimeRangeSelector({ value, onChange }: TimeRangeSelectorProps) {
  return (
    <div className="flex gap-1">
      {RANGES.map((range) => (
        <button
          key={range}
          onClick={() => onChange(range)}
          className={`px-3 py-1 text-sm rounded ${
            value === range
              ? 'bg-blue-600 text-white'
              : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
          }`}
        >
          {range}
        </button>
      ))}
    </div>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="time-range-selector" --no-coverage
```

Expected: PASS (3 tests)

- [ ] **Step 5: Implement the device detail page**

```tsx
// src/app/device/[id]/page.tsx
'use client';
import { useEffect, useState } from 'react';
import Link from 'next/link';
import AppLayout from '@/components/app-layout';
import DataTable from '@/components/data-table';
import TimeRangeSelector from '@/components/time-range-selector';
import type { DeviceDetailResponse, TimeRange } from '@/types/telemetry';

export default function DevicePage({ params }: { params: { id: string } }) {
  const { id } = params;
  const [range, setRange] = useState<TimeRange>('1h');
  const [detail, setDetail] = useState<DeviceDetailResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setLoading(true);
    setError(null);

    fetch(`/api/devices/${id}?range=${range}`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<DeviceDetailResponse>;
      })
      .then((data) => {
        setDetail(data);
        setLoading(false);
      })
      .catch((e: Error) => {
        setError(e.message);
        setLoading(false);
      });
  }, [id, range]);

  const tableColumnKeys = ['timestamp', ...(detail?.columns ?? [])];

  const tableData = (detail?.rows ?? []).map((row) => ({
    timestamp: new Date(row.timestamp).toLocaleString(),
    ...row.values,
  }));

  return (
    <AppLayout>
      <div className="space-y-4">
        {/* Breadcrumb */}
        <nav className="text-sm text-gray-500">
          <Link href="/fleet" className="hover:text-gray-900">
            Fleet
          </Link>
          <span className="mx-2">›</span>
          <span className="text-gray-900">{id}</span>
        </nav>

        {/* Header row */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-semibold text-gray-900">{id}</h1>
          <TimeRangeSelector value={range} onChange={setRange} />
        </div>

        {loading && <p className="text-gray-500">Loading...</p>}
        {error && <p className="text-red-500">Error: {error}</p>}
        {!loading && !error && detail && (
          <DataTable columnKeys={tableColumnKeys} data={tableData} />
        )}
      </div>
    </AppLayout>
  );
}
```

- [ ] **Step 6: Run all tests**

```bash
npm test -- --no-coverage
```

Expected: All tests pass.

- [ ] **Step 7: Manual end-to-end verification**

With `npm run dev` running:

1. Visit `http://localhost:3000` → redirects to `/auth/signin`
2. Sign in with a Google Workspace account → redirects to `/fleet`
3. Fleet table shows all devices with dynamically discovered columns
4. Click a row → navigates to `/device/{id}`
5. Device detail page shows breadcrumb, heading, time range selector, time-series table
6. Clicking 6h, 24h, 7d re-fetches and updates the table
7. Clicking "Fleet" in breadcrumb or sidebar returns to `/fleet`
8. Clicking "Sign out" returns to `/auth/signin`
9. Try accessing `/fleet` without a session (e.g. incognito) → redirects to `/auth/signin`
10. Try `GET /api/devices` without a session cookie → returns `{ "error": "Unauthorized" }` with status 401

- [ ] **Step 8: Commit**

```bash
git add src/components/time-range-selector.tsx src/app/device \
        __tests__/components/time-range-selector.test.tsx
git commit -m "feat(web-client): add device detail page with time-series table and range selector"
```

---

## Done

The web client is fully implemented. To run locally:

```bash
cd sample-clients/data-web-client
cp .env.local.example .env.local   # fill in credentials
gcloud auth application-default login
npm run dev
```

Open `http://localhost:3000`.
