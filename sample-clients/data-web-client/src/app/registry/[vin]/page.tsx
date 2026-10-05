'use client';
import { use, useEffect, useState } from 'react';
import Link from 'next/link';
import AppLayout from '@/components/app-layout';
import DataTable from '@/components/data-table';
import type { VinEventsResponse, VinEvent } from '@/types/registry';

function formatTimestamp(iso: string): string {
  if (!iso) return '—';
  const d = new Date(iso);
  return isNaN(d.getTime()) ? iso : d.toLocaleString();
}

export default function RegistryVinPage({ params }: { params: Promise<{ vin: string }> }) {
  const { vin } = use(params);
  const [events, setEvents] = useState<VinEvent[]>([]);
  const [unavailable, setUnavailable] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch(`/api/registry/vins/${encodeURIComponent(vin)}/events`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<VinEventsResponse>;
      })
      .then((data) => {
        setEvents(data.events);
        setUnavailable(Boolean(data.unavailable));
        setLoading(false);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setLoading(false);
      });
  }, [vin]);

  const columnKeys = ['createdAt', 'action', 'source', 'result', 'detail'];
  const data = events.map((e) => ({
    createdAt: formatTimestamp(e.created_at),
    action: e.action,
    source: e.source,
    result: e.result,
    detail: e.detail ?? '',
  }));

  return (
    <AppLayout>
      <div className="space-y-4">
        {/* Breadcrumb */}
        <nav aria-label="Breadcrumb" className="text-sm text-gray-500">
          <Link href="/registry" className="hover:text-gray-900">
            Vehicle Registry
          </Link>
          <span className="mx-2">›</span>
          <span className="text-gray-900">{vin}</span>
        </nav>

        <h1 className="text-xl font-semibold text-gray-900">
          {vin}{!loading && !unavailable && ` · ${events.length} events`}
        </h1>

        {loading && <p className="text-gray-500">Loading...</p>}
        {error && <p className="text-red-500">Error: {error}</p>}

        {!loading && !error && unavailable && (
          <p className="text-gray-500">
            No vehicle registry is configured on this platform.
          </p>
        )}

        {!loading && !error && !unavailable && events.length === 0 && (
          <p className="text-gray-500">No events recorded for this vehicle.</p>
        )}

        {!loading && !error && !unavailable && events.length > 0 && (
          <DataTable columnKeys={columnKeys} data={data} />
        )}
      </div>
    </AppLayout>
  );
}
