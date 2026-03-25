import { extractGpsPoints } from '@/lib/gps';
import type { DeviceDetailResponse } from '@/types/telemetry';

function makeDetail(
  columns: string[],
  rows: { timestamp: string; values: Record<string, string> }[],
): DeviceDetailResponse {
  return { deviceId: 'dev1', columns, rows };
}

describe('extractGpsPoints', () => {
  it('returns empty array when GPS columns are absent', () => {
    const detail = makeDetail(['dynamic:battery.temp'], []);
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('returns empty array when only some GPS columns present', () => {
    const detail = makeDetail(['dynamic:gps.latitude', 'dynamic:gps.longitude'], []);
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('extracts valid GPS points when all three columns present', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'dynamic:gps.latitude': '51.5',
            'dynamic:gps.longitude': '-0.1',
            'dynamic:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toEqual([
      { timestamp: '2026-03-25T10:00:00Z', lat: 51.5, lng: -0.1, alt: 10 },
    ]);
  });

  it('detects GPS columns case-insensitively', () => {
    const detail = makeDetail(
      ['dynamic:GPS.LATITUDE', 'dynamic:GPS.LONGITUDE', 'dynamic:GPS.ALTITUDE'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'dynamic:GPS.LATITUDE': '51.5',
            'dynamic:GPS.LONGITUDE': '-0.1',
            'dynamic:GPS.ALTITUDE': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toHaveLength(1);
  });

  it('detects GPS columns with any family prefix', () => {
    const detail = makeDetail(
      ['telemetry:gps.latitude', 'telemetry:gps.longitude', 'telemetry:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'telemetry:gps.latitude': '51.5',
            'telemetry:gps.longitude': '-0.1',
            'telemetry:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toHaveLength(1);
  });

  it('skips rows with missing coordinate values', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [{ timestamp: '2026-03-25T10:00:00Z', values: { 'dynamic:gps.latitude': '51.5' } }],
    );
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('skips rows with non-finite coordinate values', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: {
            'dynamic:gps.latitude': 'NaN',
            'dynamic:gps.longitude': '-0.1',
            'dynamic:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('skips rows with invalid timestamps', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: 'not-a-date',
          values: {
            'dynamic:gps.latitude': '51.5',
            'dynamic:gps.longitude': '-0.1',
            'dynamic:gps.altitude': '10',
          },
        },
      ],
    );
    expect(extractGpsPoints(detail)).toEqual([]);
  });

  it('sorts points by timestamp ascending', () => {
    const detail = makeDetail(
      ['dynamic:gps.latitude', 'dynamic:gps.longitude', 'dynamic:gps.altitude'],
      [
        {
          timestamp: '2026-03-25T10:01:00Z',
          values: { 'dynamic:gps.latitude': '52.0', 'dynamic:gps.longitude': '-0.2', 'dynamic:gps.altitude': '20' },
        },
        {
          timestamp: '2026-03-25T10:00:00Z',
          values: { 'dynamic:gps.latitude': '51.5', 'dynamic:gps.longitude': '-0.1', 'dynamic:gps.altitude': '10' },
        },
      ],
    );
    const result = extractGpsPoints(detail);
    expect(result[0].timestamp).toBe('2026-03-25T10:00:00Z');
    expect(result[1].timestamp).toBe('2026-03-25T10:01:00Z');
  });
});
