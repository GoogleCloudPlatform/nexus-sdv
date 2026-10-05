export interface VinSummary {
  vin: string;
  events: number;
  first_seen: string;
  last_seen: string;
  last_action: string;
  last_result: string;
}

export interface VinsResponse {
  vins: VinSummary[];
  /** True when the caller holds nexus-admin and therefore sees every identity. */
  unfiltered: boolean;
  /** True when no vin-registry is configured on this platform. */
  unavailable?: boolean;
}

export interface VinEvent {
  created_at: string;
  action: string;
  source: string;
  result: string;
  /** Accepted by the registry's write path, but no caller sends it yet. */
  detail?: string;
}

export interface VinEventsResponse {
  vin: string;
  events: VinEvent[];
  /** True when no vin-registry is configured on this platform. */
  unavailable?: boolean;
}
