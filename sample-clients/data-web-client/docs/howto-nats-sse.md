# How to: Receive NATS Messages in a Web App via Server-Sent Events

This guide explains how to bridge NATS pub/sub messages into a browser using
**Server-Sent Events (SSE)**. It uses the `data-web-client` as the reference
implementation. The pattern works in any Node.js-based web framework (Next.js,
Express, Fastify, etc.).

---

## Architecture Overview

NATS does not have a native browser SDK — it operates over a custom TCP
protocol that browsers cannot speak directly. The solution is to let the
**server** subscribe to NATS and forward messages to the browser over an HTTP
streaming response (SSE).

```
NATS Server
    │  (TCP, protobuf)
    ▼
Next.js API Route           ← server-side only
    │  (HTTP chunked / SSE)
    ▼
Browser (EventSource)       ← client-side
```

Each browser tab opens one `EventSource` connection to the API route. The
route subscribes to a NATS subject and streams every message to that tab as a
text event. When the tab closes, the stream is torn down and the NATS
subscription is unsubscribed.

---

## Step 1 — Install Dependencies

```bash
npm install nats protobufjs
```

| Package | Purpose |
|---------|---------|
| `nats` | Node.js NATS client (server-side only) |
| `protobufjs` | Runtime protobuf decode without a code-gen step |

---

## Step 2 — NATS Connection Module

Create a singleton connection so multiple API requests reuse the same TCP
connection to NATS instead of opening one per request.

**`src/lib/nats.ts`**

```typescript
import { connect, type NatsConnection } from 'nats';

// One persistent connection per process. Re-connected automatically
// if the underlying TCP socket is closed.
let _nc: NatsConnection | null = null;

export async function getNatsConnection(): Promise<NatsConnection> {
  if (!_nc || _nc.isClosed()) {
    _nc = await connect({
      servers: process.env.NATS_URL!,      // e.g. "nats://nats.internal:4222"
      user:    process.env.NATS_USER!,
      pass:    process.env.NATS_PASSWORD!,
    });
  }
  return _nc;
}
```

**Why a singleton?**  
NATS connections are TCP connections. Opening a new one per API request would
quickly exhaust both server-side file descriptors and NATS server resources.
The singleton is safe because the `nats` library internally serialises
subscribe/publish calls and the `isClosed()` guard creates a fresh connection
if the previous one was dropped.

**Multiple subjects / different credentials**  
If different parts of your app need to subscribe with different NATS
credentials (e.g. a read-only scoring user vs a general telemetry user),
create a separate singleton per credential set — as shown with
`getNatsScoringConnection()` in the reference implementation.

---

## Step 3 — Define Your Protobuf Schema

Messages on NATS are binary-encoded using protobuf. You can either import a
`.proto` file at runtime or inline the schema as a string. Inlining is
convenient for small schemas because it avoids file-system path issues in
bundled environments.

**Inline approach (used in `route.ts`)**

```typescript
import protobuf from 'protobufjs';

const SCORING_PROTO = `
  syntax = "proto3";
  package scoring;
  message ScoringMessage {
    string vehicle_id   = 1;
    string score        = 2;
    repeated string suggestions = 3;
  }
`;

// Parse once and cache the Type object.
let _ScoringMessage: protobuf.Type | null = null;

function getScoringMessageType(): protobuf.Type {
  if (!_ScoringMessage) {
    const root = protobuf.parse(SCORING_PROTO).root;
    _ScoringMessage = root.lookupType('scoring.ScoringMessage');
  }
  return _ScoringMessage;
}
```

**File-based approach**  
If your schema lives in a `.proto` file, load it with:

```typescript
const root = await protobuf.load('/path/to/scoring.proto');
const ScoringMessage = root.lookupType('scoring.ScoringMessage');
```

Either way, the result is a `protobuf.Type` object whose `.decode()` method
turns raw bytes into a plain JavaScript object.

---

## Step 4 — The SSE API Route

This is the core piece. The route:

1. Authenticates the request (optional but recommended).
2. Opens a NATS subscription.
3. Returns a `ReadableStream` as an SSE response.
4. In the stream's `start()` loop it races each incoming NATS message against
   a "client disconnected" signal, forwarding messages as SSE events.
5. In the stream's `cancel()` callback it tears down the NATS subscription the
   moment the browser closes the `EventSource`.

**`src/app/api/scoring/stream/route.ts`** (Next.js App Router)

```typescript
import { getServerSession } from 'next-auth';
import { authOptions }      from '@/lib/auth';
import { getNatsConnection } from '@/lib/nats';   // your singleton from Step 2
import protobuf              from 'protobufjs';

// --- Protobuf setup (Step 3) -----------------------------------------------
const SCORING_PROTO = `
  syntax = "proto3";
  package scoring;
  message ScoringMessage {
    string vehicle_id = 1;
    string score = 2;
    repeated string suggestions = 3;
  }
`;
let _ScoringMessage: protobuf.Type | null = null;
function getScoringMessageType(): protobuf.Type {
  if (!_ScoringMessage) {
    const root = protobuf.parse(SCORING_PROTO).root;
    _ScoringMessage = root.lookupType('scoring.ScoringMessage');
  }
  return _ScoringMessage;
}

// --- Route handler ---------------------------------------------------------
export async function GET(request: Request) {
  // 1. Auth gate — remove this block if your route is public.
  const session = await getServerSession(authOptions);
  if (!session) return new Response('Unauthorized', { status: 401 });

  // 2. NATS connection + subscription.
  let nc;
  try {
    nc = await getNatsConnection();
  } catch (err) {
    console.error('NATS connection failed:', err);
    return new Response('Service Unavailable', { status: 503 });
  }
  const sub = nc.subscribe('scoring.*');   // wildcard: all vehicles

  // 3. Disconnect detection.
  //    `cancel()` is the reliable signal in nginx-fronted deployments;
  //    `request.signal` is wired in as belt-and-braces.
  const disconnectController = new AbortController();
  const aborted = new Promise<void>((resolve) => {
    if (disconnectController.signal.aborted) resolve();
    else disconnectController.signal.addEventListener('abort', () => resolve(), { once: true });
  });
  if (request.signal.aborted) disconnectController.abort();
  else request.signal.addEventListener('abort', () => disconnectController.abort(), { once: true });

  const cleanup = () => {
    disconnectController.abort();
    try { sub.unsubscribe(); } catch { /* already gone */ }
  };

  // 4. Streaming response.
  const encoder = new TextEncoder();
  const ScoringMessage = getScoringMessageType();

  const stream = new ReadableStream({
    async start(controller) {
      // Send an initial SSE comment. This flushes the HTTP response headers
      // immediately so nginx switches into pass-through streaming mode.
      // Without this, nginx buffers the response until the first real message
      // arrives — and in that buffered window it cannot detect a closed client
      // socket, so cancel() never fires.
      // SSE comments (lines starting with ':') are silently ignored by
      // the browser's EventSource API.
      controller.enqueue(encoder.encode(': connected\n\n'));

      try {
        const iter = sub[Symbol.asyncIterator]();
        while (true) {
          // Race the next NATS message against client disconnect.
          const next = await Promise.race([
            iter.next().then((r) => ({ kind: 'msg'   as const, result: r })),
            aborted.then(()    => ({ kind: 'abort' as const })),
          ]);
          if (next.kind === 'abort') break;
          if (next.result.done)      break;

          const msg = next.result.value;
          try {
            // Decode the protobuf payload and build the SSE event string.
            const decoded = ScoringMessage.decode(msg.data).toJSON() as Record<string, unknown>;
            const vehicleId   = String(decoded['vehicleId']   ?? decoded['vehicle_id'] ?? '');
            const score       = String(decoded['score']       ?? '');
            const suggestions = (decoded['suggestions'] as string[] | undefined) ?? [];
            const text = `${vehicleId} - ${score} - ${suggestions.join(', ')}`;

            // SSE format: "data: <payload>\n\n"
            controller.enqueue(encoder.encode(`data: ${text}\n\n`));
          } catch (decodeErr) {
            console.error('Protobuf decode error:', decodeErr);
            // Skip malformed messages; keep the stream alive.
          }
        }
      } catch (err) {
        console.error('NATS stream error:', err);
      } finally {
        cleanup();
        try { controller.close(); } catch { /* already closed */ }
      }
    },

    // Fires when the browser closes its EventSource (tab close, navigation,
    // or explicit source.close()). Triggers cleanup → unsubscribes from NATS
    // and breaks the start() loop via the aborted promise.
    cancel() {
      cleanup();
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type':      'text/event-stream',
      'Cache-Control':     'no-cache',
      'Connection':        'keep-alive',
      // Tell nginx NOT to buffer this response.
      // Without this header, nginx will hold chunks in its buffer and will
      // not detect a closed client TCP socket, so cancel() never fires.
      'X-Accel-Buffering': 'no',
    },
  });
}
```

### Adapting to Express / Fastify

The same logic applies; the only difference is the response API:

```javascript
// Express
app.get('/stream', async (req, res) => {
  res.setHeader('Content-Type',      'text/event-stream');
  res.setHeader('Cache-Control',     'no-cache');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();          // flush immediately (replaces ': connected\n\n')

  const nc  = await getNatsConnection();
  const sub = nc.subscribe('scoring.*');

  req.on('close', () => sub.unsubscribe());

  for await (const msg of sub) {
    const decoded = ScoringMessage.decode(msg.data).toJSON();
    res.write(`data: ${JSON.stringify(decoded)}\n\n`);
  }
});
```

---

## Step 5 — Consume the SSE Stream in React

**`src/hooks/useScoringMessages.ts`**

```typescript
'use client';

import { useEffect, useState } from 'react';

const MAX_MESSAGES = 100;

export function useScoringMessages() {
  const [messages, setMessages] = useState<string[]>([]);

  // Hydrate from sessionStorage on mount to survive page reloads.
  // Wrapped in its own effect (not a lazy useState initialiser) so the
  // first render is identical on server and client, avoiding hydration
  // mismatches.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    try {
      const raw = window.sessionStorage.getItem('scoringMessages');
      if (raw) {
        const parsed = JSON.parse(raw) as unknown;
        if (Array.isArray(parsed))
          setMessages(parsed.filter((m): m is string => typeof m === 'string').slice(0, MAX_MESSAGES));
      }
    } catch { /* corrupted — start fresh */ }
  }, []);

  // Open the SSE stream once on mount.
  useEffect(() => {
    const source = new EventSource('/api/scoring/stream');

    source.onmessage = (e) => {
      setMessages((prev) => {
        // Newest message at index 0, capped at MAX_MESSAGES.
        const next = [e.data, ...prev].slice(0, MAX_MESSAGES);
        try { window.sessionStorage.setItem('scoringMessages', JSON.stringify(next)); } catch {}
        return next;
      });
    };

    source.onerror = () => source.close();
    return () => source.close();   // cleanup on unmount
  }, []);

  return messages;
}
```

Use it in any component:

```tsx
import { useScoringMessages } from '@/hooks/useScoringMessages';

export default function ScoringPanel() {
  const messages = useScoringMessages();
  return (
    <ul>
      {messages.map((msg, i) => <li key={i}>{msg}</li>)}
    </ul>
  );
}
```

---

## Step 6 — Consume the SSE Stream in Vanilla JavaScript

For static HTML pages (or any non-framework context):

```javascript
let scoringStream = null;

function openScoringStream() {
  if (scoringStream) return;                          // already open
  scoringStream = new EventSource('/api/scoring/stream');

  scoringStream.onmessage = (e) => {
    // e.data = "vehicleId - score - suggestion1, suggestion2"
    const parts = (e.data || '').split(' - ');
    if (parts.length < 2) return;

    const vehicleId   = parts[0].trim();
    const score       = parts[1].trim();
    const suggestions = parts[2] ? parts[2].split(', ') : [];

    console.log('Score for', vehicleId, ':', score, suggestions);
    // Update your UI here.
  };

  scoringStream.onerror = () => closeScoringStream();
}

function closeScoringStream() {
  if (scoringStream) {
    scoringStream.close();
    scoringStream = null;
  }
}

// Open on page load:
openScoringStream();

// Close cleanly on navigation away:
window.addEventListener('pagehide', closeScoringStream);
```

**Optional: VIN filter**  
Filter messages client-side without touching the server:

```javascript
scoringStream.onmessage = (e) => {
  const parts = (e.data || '').split(' - ');
  if (parts.length < 2) return;

  const vinFilter = document.getElementById('vinFilter').value.trim();
  if (vinFilter && parts[0].trim() !== vinFilter) return;   // skip non-matching

  // Process message ...
};
```

---

## Step 7 — Environment Variables

Add the following to `.env.local` (development) or your secret manager
(production):

```ini
# NATS server address — internal cluster DNS in production
NATS_URL=nats://nats.nats.svc.cluster.local:4222

# General-purpose NATS user (telemetry, etc.)
NATS_USER=your-nats-user
NATS_PASSWORD=your-nats-password

# Separate credentials for the scoring subject (least-privilege)
NATS_SCORING_USER=connector
NATS_SCORING_PASSWORD=your-scoring-password
```

---

## Step 8 — nginx / Reverse Proxy Configuration

If an nginx sidecar or ingress sits in front of your Node.js server, two
problems arise with SSE by default:

| Problem | Symptom | Fix |
|---------|---------|-----|
| nginx buffers the response | First message delayed; client disconnects not detected | `proxy_buffering off` in the location block |
| Read timeout too short | Stream drops after 60 s | `proxy_read_timeout 24h` |
| Response-level buffering | Same as row 1 | `X-Accel-Buffering: no` header from the app |

**Minimal nginx location block for an SSE endpoint:**

```nginx
location /api/scoring/stream {
  proxy_pass         http://localhost:3000;
  proxy_set_header   Host              $host;
  proxy_set_header   X-Real-IP         $remote_addr;
  proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
  proxy_set_header   X-Forwarded-Proto https;

  proxy_buffering             off;       # disable response buffering
  proxy_cache                 off;       # never cache SSE
  proxy_read_timeout          24h;       # keep the connection alive for hours
  chunked_transfer_encoding   on;        # let chunks pass through immediately
}
```

The `X-Accel-Buffering: no` header set inside the route handler overrides
nginx's `proxy_buffering` on a per-response basis and acts as a reliable
fallback if the nginx config cannot be changed.

**Why the initial `: connected\n\n` comment matters**  
Nginx does not switch into streaming pass-through mode until it sees the first
byte of the response body. If no NATS message arrives immediately, nginx
buffers the response while waiting — and in that buffered state it cannot
detect the client closing the TCP socket. The SSE comment sent at stream open
forces an immediate flush, resolving both the lag and the disconnect-detection
problem.

---

## Step 9 — GKE / Helm Deployment

**Helm values** (`values.yaml`)

```yaml
nats:
  url: "nats://nats.nats.svc.cluster.local:4222"

externalSecretsEnabled: true
externalSecrets:
  natsUserSecretName:     NATS_SERVER_USER
  natsPasswordSecretName: NATS_SERVER_PASSWORD
```

**Kubernetes deployment env block** (generated by the Helm chart)

```yaml
- name: NATS_URL
  value: "nats://nats.nats.svc.cluster.local:4222"
- name: NATS_USER
  valueFrom:
    secretKeyRef:
      name: data-web-client-nats-secret
      key:  NATS_USER
- name: NATS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: data-web-client-nats-secret
      key:  NATS_PASSWORD
- name: NATS_SCORING_USER
  value: "connector"
- name: NATS_SCORING_PASSWORD
  valueFrom:
    secretKeyRef:
      name: data-web-client-nats-secret
      key:  NATS_SCORING_PASSWORD
```

Secrets are provisioned via **External Secrets Operator**, pulling from GCP
Secret Manager into Kubernetes secrets. No secret values are stored in the
Helm chart or version control.

---

## Summary: Files to Copy

| File | What it does |
|------|-------------|
| `src/lib/nats.ts` | Singleton NATS connection(s) |
| `src/app/api/scoring/stream/route.ts` | SSE route: subscribes to NATS, streams to browser |
| `src/hooks/useScoringMessages.ts` | React hook: consumes SSE, persists to sessionStorage |
| `nginx.conf` (location block) | Proxy config for SSE pass-through |

---

## Common Pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| Stream never receives messages | NATS subject name typo or wrong credentials | Log `msg.subject` on each received message server-side |
| `Protobuf decode error` | Message on the subject uses a different schema | Verify producer's `.proto` matches the consumer's |
| Stream stays open after tab close | nginx is buffering; `cancel()` never fires | Add `proxy_buffering off` + send initial `: connected\n\n` flush |
| `Service Unavailable` on route hit | NATS unreachable from the app pod | Check `NATS_URL` and network policy; confirm NATS pod is healthy |
| Score trend shows `NaN` | Parsing the score string before the previous value is set | Guard with `Number.isFinite()` before computing `current - previous` |
