'use client';
import { use, useEffect, useState } from 'react';
import Link from 'next/link';
import AppLayout from '@/components/app-layout';
import DataTable from '@/components/data-table';
import TimeRangeSelector from '@/components/time-range-selector';
import type { DeviceDetailResponse, TimeRange } from '@/types/telemetry';
import { extractGpsPoints } from '@/lib/gps';
import GpsTrackMap from '@/components/gps-track-map';

export default function DevicePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [range, setRange] = useState<TimeRange>('1h');
  const [detail, setDetail] = useState<DeviceDetailResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setLoading(true);
    setError(null);

    fetch(`/api/devices/${id}?range=${range}`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<DeviceDetailResponse>;
      })
      .then((data) => {
        setDetail(data);
        setLoading(false);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setLoading(false);
      });
  }, [id, range]);

  const tableColumnKeys = ['timestamp', ...(detail?.columns ?? [])];

  const tableData = (detail?.rows ?? []).map((row) => ({
    timestamp: new Date(row.timestamp).toLocaleString(),
    ...row.values,
  }));

  const gpsPoints = detail ? extractGpsPoints(detail) : [];

  return (
    <AppLayout>
      <div className="space-y-4">
        {/* Breadcrumb */}
        <nav aria-label="Breadcrumb" className="text-sm text-gray-500">
          <Link href="/fleet" className="hover:text-gray-900">
            Fleet
          </Link>
          <span className="mx-2">›</span>
          <span className="text-gray-900">{id}</span>
        </nav>

        {/* Header row */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-semibold text-gray-900">{id}</h1>
          <TimeRangeSelector value={range} onChange={setRange} />
        </div>

        {loading && <p className="text-gray-500">Loading...</p>}
        {error && <p className="text-red-500">Error: {error}</p>}
        {!loading && !error && detail && (
          <div className="space-y-4">
            <DataTable columnKeys={tableColumnKeys} data={tableData} />
            {gpsPoints.length > 0 && <GpsTrackMap points={gpsPoints} />}
          </div>
        )}
      </div>
    </AppLayout>
  );
}
