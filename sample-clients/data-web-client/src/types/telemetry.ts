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
