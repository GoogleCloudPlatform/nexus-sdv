import { getServerSession } from 'next-auth';
import { authOptions } from '@/lib/auth';
import { getNatsScoringConnection } from '@/lib/nats';
import protobuf from 'protobufjs';

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

export async function GET(request: Request) {
  const session = await getServerSession(authOptions);
  if (!session) {
    return new Response('Unauthorized', { status: 401 });
  }

  let nc;
  try {
    nc = await getNatsScoringConnection();
    console.log('[/api/scoring/stream] NATS connected, subscribing to scoring.*');
  } catch (err) {
    console.error('[/api/scoring/stream] NATS connection failed:', err);
    return new Response('Service Unavailable', { status: 503 });
  }

  const ScoringMessage = getScoringMessageType();
  const sub = nc.subscribe('scoring.*');

  // Promise that resolves the moment the client disconnects so the start()
  // loop below can stop awaiting the next NATS message and exit. We feed
  // it from BOTH `request.signal.abort` AND the ReadableStream `cancel()`
  // callback so whichever fires first wins. In practice cancel() is the
  // reliable signal in this Next.js + nginx + GKE setup; request.signal
  // is wired in as a cheap belt-and-braces.
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

  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      // Push an initial comment so nginx (sidecar in front of this pod)
      // flushes the response immediately and switches into streaming mode.
      // Without this, nginx response-buffers the first chunk until a NATS
      // message arrives — and during that buffered window it doesn't
      // notice the client closing its TCP socket, so cancel() never
      // fires. SSE comments (`:` prefix) are ignored by EventSource.
      controller.enqueue(encoder.encode(': connected\n\n'));

      try {
        const iter = sub[Symbol.asyncIterator]();
        // Race the next NATS message against client disconnect. Whichever
        // resolves first wins; if `aborted` wins, we break and run cleanup.
        while (true) {
          const next = await Promise.race([
            iter.next().then((r) => ({ kind: 'msg' as const, result: r })),
            aborted.then(() => ({ kind: 'abort' as const })),
          ]);
          if (next.kind === 'abort') break;
          if (next.result.done) break;
          const msg = next.result.value;
          console.log('[/api/scoring/stream] Received NATS message, subject:', msg.subject, 'bytes:', msg.data.length);
          try {
            const decoded = ScoringMessage.decode(msg.data).toJSON() as Record<string, unknown>;
            const vehicleId = decoded['vehicleId'] ?? decoded['vehicle_id'] ?? '';
            const score = decoded['score'] ?? '';
            const suggestions = (decoded['suggestions'] as string[] | undefined) ?? [];
            const text = `${vehicleId} - ${score} - ${suggestions.join(', ')}`;
            controller.enqueue(encoder.encode(`data: ${text}\n\n`));
          } catch (decodeErr: unknown) {
            console.error('[/api/scoring/stream] Failed to decode message:', decodeErr);
          }
        }
      } catch (err) {
        console.error('[/api/scoring/stream] NATS stream error:', err);
      } finally {
        cleanup();
        try { controller.close(); } catch { /* already closed */ }
        console.log('[/api/scoring/stream] Stream closed');
      }
    },
    // Fires when the client cancels the response stream (e.g., browser
    // closes the EventSource). Triggers cleanup which aborts the
    // disconnectController and lets the start() loop exit.
    cancel() {
      cleanup();
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      // Tell nginx (sidecar / ingress) NOT to buffer this response.
      // Without this header nginx will buffer chunks up to its
      // proxy_buffer_size before forwarding them, which delays both the
      // first byte to the client and the propagation of client
      // disconnects back to upstream.
      'X-Accel-Buffering': 'no',
    },
  });
}
