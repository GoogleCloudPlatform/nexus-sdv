'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import AppLayout from '@/components/app-layout';
import DataTable from '@/components/data-table';
import type { DevicesResponse, DeviceRow } from '@/types/telemetry';

function formatLastSeen(iso: string): string {
  if (!iso) return '—';
  const diff = Date.now() - new Date(iso).getTime();
  if (isNaN(diff) || diff < 0) return new Date(iso).toLocaleString();
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  return new Date(iso).toLocaleString();
}

export default function FleetPage() {
  const router = useRouter();
  const [devices, setDevices] = useState<DeviceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch('/api/devices')
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<DevicesResponse>;
      })
      .then((data) => {
        setDevices(data.devices);
        setLoading(false);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setLoading(false);
      });
  }, []);

  const isGpsColumn = (key: string) => {
    const qualifier = key.includes(':') ? key.slice(key.indexOf(':') + 1) : key;
    return qualifier.toLowerCase().startsWith('gps.');
  };

  // Build flat rows and column key list for the table, excluding GPS columns
  const allColumnKeys = Array.from(
    new Set(devices.flatMap((d) => Object.keys(d.columns).filter((k) => !isGpsColumn(k))))
  ).sort();

  const tableColumnKeys = ['deviceId', 'lastSeen', ...allColumnKeys];

  const tableData = devices.map((d) => ({
    deviceId: d.deviceId,
    lastSeen: formatLastSeen(d.lastSeen),
    ...d.columns,
  }));

  return (
    <AppLayout>
      <div className="space-y-4">
        <h1 className="text-xl font-semibold text-gray-900">
          Fleet{!loading && ` · ${devices.length} devices`}
        </h1>

        {loading && <p className="text-gray-500">Loading...</p>}
        {error && <p className="text-red-500">Error: {error}</p>}
        {!loading && !error && (
          <DataTable
            columnKeys={tableColumnKeys}
            data={tableData}
            onRowClick={(row) => router.push(`/device/${row.deviceId}`)}
          />
        )}
      </div>
    </AppLayout>
  );
}
