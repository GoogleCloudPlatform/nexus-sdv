'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import AppLayout from '@/components/app-layout';
import DataTable from '@/components/data-table';
import type { VinsResponse, VinSummary } from '@/types/registry';

function formatTimestamp(iso: string): string {
  if (!iso) return '—';
  const d = new Date(iso);
  return isNaN(d.getTime()) ? iso : d.toLocaleString();
}

export default function RegistryPage() {
  const router = useRouter();
  const [vins, setVins] = useState<VinSummary[]>([]);
  const [unfiltered, setUnfiltered] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch('/api/registry/vins')
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<VinsResponse>;
      })
      .then((data) => {
        setVins(data.vins);
        setUnfiltered(data.unfiltered);
        setUnavailable(Boolean(data.unavailable));
        setLoading(false);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setLoading(false);
      });
  }, []);

  const columnKeys = ['vin', 'lastAction', 'lastResult', 'events', 'firstSeen', 'lastSeen'];
  const data = vins.map((v) => ({
    vin: v.vin,
    lastAction: v.last_action,
    lastResult: v.last_result,
    events: String(v.events),
    firstSeen: formatTimestamp(v.first_seen),
    lastSeen: formatTimestamp(v.last_seen),
  }));

  return (
    <AppLayout>
      <div className="space-y-4">
        <h1 className="text-xl font-semibold text-gray-900">
          Vehicle Registry{!loading && !unavailable && ` · ${vins.length} vehicles`}
        </h1>

        {!loading && !unavailable && (
          <p className="text-sm text-gray-500">
            {unfiltered
              ? 'Showing every identity on this platform.'
              : 'Showing the vehicles of your fleet.'}
          </p>
        )}

        {loading && <p className="text-gray-500">Loading...</p>}
        {error && <p className="text-red-500">Error: {error}</p>}

        {!loading && !error && unavailable && (
          <p className="text-gray-500">
            No vehicle registry is configured on this platform.
          </p>
        )}

        {!loading && !error && !unavailable && vins.length === 0 && (
          <p className="text-gray-500">
            No vehicles recorded yet. A vehicle appears here once it has been
            issued a certificate by the factory helper or the registration server.
          </p>
        )}

        {!loading && !error && !unavailable && vins.length > 0 && (
          <DataTable
            columnKeys={columnKeys}
            data={data}
            onRowClick={(row) => router.push(`/registry/${row.vin}`)}
          />
        )}
      </div>
    </AppLayout>
  );
}
