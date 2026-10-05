import { GET } from '@/app/api/scoring/stream/route';
import protobuf from 'protobufjs';

const mockGetServerSession = jest.fn();
const mockGetNatsConnection = jest.fn();

jest.mock('next-auth', () => ({ getServerSession: (...a: unknown[]) => mockGetServerSession(...a) }));
jest.mock('@/lib/auth', () => ({ authOptions: {} }));
jest.mock('@/lib/nats', () => ({ getNatsScoringConnection: (...a: unknown[]) => mockGetNatsConnection(...a) }));
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

const ScoringMessage = protobuf
  .parse('syntax = "proto3"; package scoring; message ScoringMessage { string vehicle_id = 1; string score = 2; repeated string suggestions = 3; }')
  .root.lookupType('scoring.ScoringMessage');

function encodeScoring(fields: { vehicleId: string; score: string; suggestions?: string[] }): Uint8Array {
  return ScoringMessage.encode(ScoringMessage.create({ suggestions: [], ...fields })).finish();
}

async function* makeRawMessages(payloads: Uint8Array[]) {
  for (const data of payloads) {
    yield { data };
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

  it('streams decoded ScoringMessages as SSE events', async () => {
    mockGetServerSession.mockResolvedValueOnce({ user: { name: 'test' } });
    // The route decodes protobuf scoring.ScoringMessage and emits
    // "<vehicle> - <score> - <suggestions>", so the test sends real protobuf.
    const sub = {
      [Symbol.asyncIterator]: () => makeRawMessages([
        encodeScoring({ vehicleId: 'VIN-1', score: '42', suggestions: ['brake earlier', 'slow down'] }),
        encodeScoring({ vehicleId: 'VIN-2', score: '99' }),
      ]),
      unsubscribe: jest.fn(),
    };
    mockGetNatsConnection.mockResolvedValueOnce({ subscribe: () => sub });

    const res = await GET(makeAbortableRequest());
    const text = await res.text();

    expect(text).toContain('data: VIN-1 - 42 - brake earlier, slow down\n\n');
    expect(text).toContain('data: VIN-2 - 99 - \n\n');
  });
});
