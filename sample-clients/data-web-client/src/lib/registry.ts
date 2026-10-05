import type { VinSummary, VinEvent } from '@/types/registry';

/**
 * Reads the vehicle identities recorded by vin-registry.
 *
 * Returns undefined when VIN_REGISTRY_URL is unset: the registry is an optional
 * companion service, and FleetView must keep working on a platform that does not
 * run it. Callers render an explanatory empty state rather than an error.
 */
export async function getVins(): Promise<VinSummary[] | undefined> {
  const base = process.env.VIN_REGISTRY_URL;
  if (!base) return undefined;

  const res = await fetch(`${base}/v1/vins`, {
    cache: 'no-store',
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`vin-registry responded HTTP ${res.status}`);
  const body = (await res.json()) as { vins?: VinSummary[] };
  return body.vins ?? [];
}

/**
 * Reads one vehicle's complete event history, newest first.
 *
 * Returns undefined for the same reason getVins does: no VIN_REGISTRY_URL means
 * this platform runs no registry, which is not an error. A VIN the registry has
 * never seen is not an error either — it answers with an empty list.
 *
 * Whether the caller may see this vehicle at all is decided by the API route,
 * which knows the user's groups; the registry does not.
 */
export async function getVinEvents(vin: string): Promise<VinEvent[] | undefined> {
  const base = process.env.VIN_REGISTRY_URL;
  if (!base) return undefined;

  const res = await fetch(`${base}/v1/vins/${encodeURIComponent(vin)}/events`, {
    cache: 'no-store',
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`vin-registry responded HTTP ${res.status}`);
  const body = (await res.json()) as { events?: VinEvent[] };
  return body.events ?? [];
}
