import { GET } from '@/app/api/scoring/stream/route';

const mockGetServerSession = jest.fn();
const mockGetNatsConnection = jest.fn();

jest.mock('next-auth', () => ({ getServerSession: (...a: unknown[]) => mockGetServerSession(...a) }));
jest.mock('@/lib/auth', () => ({ authOptions: {} }));
jest.mock('@/lib/nats', () => ({ getNatsConnection: (...a: unknown[]) => mockGetNatsConnection(...a) }));
jest.mock('nats', () => ({
  StringCodec: () => ({ decode: (d: Uint8Array) => Buffer.from(d).toString() }),
}));

function makeAbortableRequest(): Request {
  const controller = new AbortController();
  const req = new Request('http://localhost/api/scoring/stream', { signal: controller.signal });
  return req;
}

async function* makeMessages(payloads: string[]) {
  for (const p of payloads) {
    yield { data: Buffer.from(p) };
  }
}

describe('GET /api/scoring/stream', () => {
  beforeEach(() => {
    mockGetServerSession.mockReset();
    mockGetNatsConnection.mockReset();
  });

  it('returns 401 when unauthenticated', async () => {
    mockGetServerSession.mockResolvedValueOnce(null);

    const res = await GET(makeAbortableRequest());

    expect(res.status).toBe(401);
  });

  it('returns SSE response with correct headers when authenticated', async () => {
    mockGetServerSession.mockResolvedValueOnce({ user: { name: 'test' } });
    const sub = { [Symbol.asyncIterator]: () => makeMessages([]), unsubscribe: jest.fn() };
    mockGetNatsConnection.mockResolvedValueOnce({ subscribe: () => sub });

    const res = await GET(makeAbortableRequest());

    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toBe('text/event-stream');
    expect(res.headers.get('Cache-Control')).toBe('no-cache');
  });

  it('streams NATS messages as SSE events', async () => {
    mockGetServerSession.mockResolvedValueOnce({ user: { name: 'test' } });
    const sub = {
      [Symbol.asyncIterator]: () => makeMessages(['{"score":42}', '{"score":99}']),
      unsubscribe: jest.fn(),
    };
    mockGetNatsConnection.mockResolvedValueOnce({ subscribe: () => sub });

    const res = await GET(makeAbortableRequest());
    const text = await res.text();

    expect(text).toContain('data: {"score":42}\n\n');
    expect(text).toContain('data: {"score":99}\n\n');
  });
});
