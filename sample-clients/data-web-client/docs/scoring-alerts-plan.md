# Plan: NATS `scoring.*` Subscription & Browser Alerts

## Subquestion: Browser TypeScript vs. other solutions

**Browser-only (e.g. `nats.ws`) — unlikely / not feasible as-is.**
The NATS server currently only exposes TCP port 4222. Browsers cannot speak raw TCP — they need
WebSocket. The NATS Helm values have no `websocket` listener configured. Adding one is possible
but it also means exposing NATS credentials inside browser JavaScript, which is a security problem
with the existing username/password auth scheme.

**The natural fit: Next.js API Route (server-side) + Server-Sent Events (SSE).**
This is the standard pattern for this exact use case in Next.js:

```
Browser  ──EventSource──▶  /api/scoring/stream  (Next.js route handler, Node.js)
                                    │
                              nats npm package
                                    │  TCP :4222
                             NATS server — scoring.*
```

- The route handler runs in Node.js, connects to NATS over TCP using existing `NATS_USER` /
  `NATS_PASSWORD` credentials (already available as env vars in the web-client pod).
- Each browser tab opens one `EventSource` to `/api/scoring/stream`.
- The route handler pushes each `scoring.*` message as an SSE event; the browser `onmessage`
  handler calls `alert()`.
- Auth-gated via `getServerSession()` — same pattern as `/api/devices`.
- No NATS credential exposure to the browser, no new ports, no changes to the NATS server.

---

## Implementation Plan

### Files to create / modify

| Action | Path |
|---|---|
| **Modify** | `package.json` (add `nats` dep) |
| **Create** | `src/lib/nats.ts` |
| **Create** | `src/app/api/scoring/stream/route.ts` |
| **Create** | `src/components/ScoringAlerts.tsx` |
| **Modify** | `src/app/layout.tsx` |

---

### Step 1 — Install `nats` npm package

```bash
npm install nats
```

The `nats` v2 package works in Node.js over TCP. No WebSocket or NATS server changes needed.

---

### Step 2 — `src/lib/nats.ts`

Singleton NATS connection reused across SSE requests (one TCP connection shared by all tabs):

```ts
import { connect, type NatsConnection } from 'nats';

let _nc: NatsConnection | null = null;

export async function getNatsConnection(): Promise<NatsConnection> {
  if (!_nc || _nc.isClosed()) {
    _nc = await connect({
      servers: process.env.NATS_URL!,
      user: process.env.NATS_USER!,
      pass: process.env.NATS_PASSWORD!,
    });
  }
  return _nc;
}
```

---

### Step 3 — `src/app/api/scoring/stream/route.ts`

SSE route handler — auth-gated, subscribes to `scoring.*`, streams each message as an SSE event:

```ts
import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getNatsConnection } from '@/lib/nats';
import { StringCodec } from 'nats';

export async function GET(request: Request) {
  const session = await getServerSession(authOptions);
  if (!session) {
    return new Response('Unauthorized', { status: 401 });
  }

  const nc = await getNatsConnection();
  const sc = StringCodec();
  const sub = nc.subscribe('scoring.*');

  const stream = new ReadableStream({
    async start(controller) {
      for await (const msg of sub) {
        const payload = sc.decode(msg.data);
        controller.enqueue(`data: ${payload}\n\n`);
      }
    },
    cancel() {
      sub.unsubscribe();
    },
  });

  request.signal.addEventListener('abort', () => sub.unsubscribe());

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    },
  });
}
```

---

### Step 4 — `src/components/ScoringAlerts.tsx`

Client component — mounts once, opens the SSE connection, fires `alert()` per message:

```tsx
'use client';

import { useEffect } from 'react';

export function ScoringAlerts() {
  useEffect(() => {
    const source = new EventSource('/api/scoring/stream');
    source.onmessage = (e) => {
      alert(`scoring event:\n${e.data}`);
    };
    source.onerror = () => source.close();
    return () => source.close();
  }, []);

  return null;
}
```

---

### Step 5 — Mount in `src/app/layout.tsx`

Add `<ScoringAlerts />` inside the `SessionProvider` so it only activates for authenticated users:

```tsx
import { ScoringAlerts } from '@/components/ScoringAlerts';
// ...
<SessionProvider>
  <ScoringAlerts />
  {children}
</SessionProvider>
```

---

## Verification

1. Publish a test message from the nats-box pod:
   ```bash
   nats pub scoring.test '{"score":42}'
   ```
2. Open the fleet view in a browser tab — an `alert()` should pop with the JSON payload.
3. Close the tab → server-side subscription cleaned up (check `http://nats-host:8222/subsz`).

---

## Open Question

What format does `scoring.*` carry — plain JSON, protobuf, or something else? If protobuf, the
SSE handler needs a decode step before passing to `alert()`. Current plan assumes plain text / JSON.
