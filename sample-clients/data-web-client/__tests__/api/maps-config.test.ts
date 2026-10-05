import { GET } from '@/app/api/maps-config/route';

describe('GET /api/maps-config', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  it('returns the configured key and map id', async () => {
    process.env.GOOGLE_MAPS_API_KEY = 'real-key';
    process.env.GOOGLE_MAPS_MAP_ID = 'real-map-id';

    const body = await (await GET()).json();

    expect(body).toEqual({ apiKey: 'real-key', mapId: 'real-map-id' });
  });

  it('treats the UNSET sentinel as no key, so the map stays hidden', async () => {
    process.env.GOOGLE_MAPS_API_KEY = 'UNSET';
    process.env.GOOGLE_MAPS_MAP_ID = 'UNSET';

    const body = await (await GET()).json();

    expect(body).toEqual({ apiKey: '', mapId: 'DEMO_MAP_ID' });
  });

  it('returns an empty key when nothing is configured', async () => {
    delete process.env.GOOGLE_MAPS_API_KEY;
    delete process.env.GOOGLE_MAPS_MAP_ID;

    const body = await (await GET()).json();

    expect(body).toEqual({ apiKey: '', mapId: 'DEMO_MAP_ID' });
  });
});
