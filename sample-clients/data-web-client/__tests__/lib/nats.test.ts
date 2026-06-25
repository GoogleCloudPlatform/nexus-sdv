import { getNatsConnection, _resetNatsConnection } from '@/lib/nats';

const mockConnect = jest.fn();
const mockClose = jest.fn();

jest.mock('nats', () => ({
  connect: (...args: unknown[]) => mockConnect(...args),
  StringCodec: jest.fn(() => ({ decode: (d: Uint8Array) => Buffer.from(d).toString() })),
}));

function makeConn(closed = false) {
  return { isClosed: () => closed, close: mockClose };
}

beforeEach(() => {
  _resetNatsConnection();
  mockConnect.mockReset();
  jest.resetModules();
  process.env.NATS_URL = 'nats://localhost:4222';
  process.env.NATS_USER = 'testuser';
  process.env.NATS_PASSWORD = 'testpass';
});

describe('getNatsConnection', () => {
  it('creates a new connection on first call', async () => {
    const conn = makeConn();
    mockConnect.mockResolvedValueOnce(conn);

    const result = await getNatsConnection();

    expect(mockConnect).toHaveBeenCalledTimes(1);
    expect(mockConnect).toHaveBeenCalledWith({
      servers: 'nats://localhost:4222',
      user: 'testuser',
      pass: 'testpass',
    });
    expect(result).toBe(conn);
  });

  it('returns the cached connection on subsequent calls', async () => {
    const conn = makeConn();
    mockConnect.mockResolvedValueOnce(conn);

    await getNatsConnection();
    await getNatsConnection();

    expect(mockConnect).toHaveBeenCalledTimes(1);
  });

  it('reconnects when the cached connection is closed', async () => {
    const closed = makeConn(true);
    const fresh = makeConn(false);
    mockConnect.mockResolvedValueOnce(closed).mockResolvedValueOnce(fresh);

    await getNatsConnection();
    _resetNatsConnection();
    mockConnect.mockResolvedValueOnce(fresh);
    const result = await getNatsConnection();

    expect(result).toBe(fresh);
  });
});
