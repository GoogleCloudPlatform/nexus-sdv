'use client';
import { use, useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import AppLayout from '@/components/app-layout';
import DataTable from '@/components/data-table';
import TimeRangeSelector from '@/components/time-range-selector';
import type { DeviceDetailResponse, TimeRange } from '@/types/telemetry';
import { extractGpsPoints } from '@/lib/gps';
import GpsTrackMap from '@/components/gps-track-map';

interface MapsConfig {
  apiKey: string;
  mapId: string;
}

export default function DevicePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [range, setRange] = useState<TimeRange>('1h');
  const [pageSize, setPageSize] = useState(25);
  const [detail, setDetail] = useState<DeviceDetailResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [mapsConfig, setMapsConfig] = useState<MapsConfig | null>(null);

  // cursor stack: index 0 = first page (no cursor), each subsequent entry is the nextCursor for that page
  const [cursorStack, setCursorStack] = useState<Array<string | null>>([null]);
  const [pageIndex, setPageIndex] = useState(0);

  // Use a ref to hold stable columns across pages so the table header doesn't jump
  const [columns, setColumns] = useState<string[]>([]);

  useEffect(() => {
    fetch('/api/maps-config')
      .then((r) => r.json() as Promise<MapsConfig>)
      .then(setMapsConfig)
      .catch(() => {/* maps config unavailable */});
  }, []);

  const fetchPage = useCallback((cursor: string | null, size: number, currentRange: TimeRange) => {
    setLoading(true);
    setError(null);
    const url = new URL(`/api/devices/${id}`, window.location.origin);
    url.searchParams.set('range', currentRange);
    url.searchParams.set('pageSize', String(size));
    if (cursor) url.searchParams.set('cursor', cursor);

    fetch(url.toString())
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<DeviceDetailResponse>;
      })
      .then((data) => {
        setDetail(data);
        // Merge new columns into the known set so header is stable across pages
        setColumns((prev) => {
          const merged = new Set([...prev, ...data.columns]);
          return Array.from(merged);
        });
        setLoading(false);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setLoading(false);
      });
  }, [id]);

  // Reset on range or pageSize change
  useEffect(() => {
    setCursorStack([null]);
    setPageIndex(0);
    setColumns([]);
    fetchPage(null, pageSize, range);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, range]);

  // Auto-refresh every 30 seconds, but only when the user is viewing the
  // first (newest) page. Refreshing while paginated to an older page would
  // shift the user's view as new rows arrive at the top, so we pause the
  // timer for pageIndex > 0.
  useEffect(() => {
    if (pageIndex !== 0) return;
    const intervalId = setInterval(() => {
      fetchPage(null, pageSize, range);
    }, 30_000);
    return () => clearInterval(intervalId);
  }, [pageIndex, pageSize, range, fetchPage]);

  function handleNext() {
    if (!detail?.nextCursor) return;
    const nextCursor = detail.nextCursor;
    const newStack = [...cursorStack.slice(0, pageIndex + 1), nextCursor];
    setCursorStack(newStack);
    setPageIndex(pageIndex + 1);
    fetchPage(nextCursor, pageSize, range);
  }

  function handlePrev() {
    if (pageIndex === 0) return;
    const newIndex = pageIndex - 1;
    setPageIndex(newIndex);
    fetchPage(cursorStack[newIndex] ?? null, pageSize, range);
  }

  function handlePageSizeChange(size: number) {
    setPageSize(size);
    setCursorStack([null]);
    setPageIndex(0);
    setColumns([]);
    fetchPage(null, size, range);
  }

  const tableColumnKeys = ['timestamp', ...columns];

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

        {error && <p className="text-red-500">Error: {error}</p>}
        {(loading || detail) && (
          <div className="space-y-4">
            <DataTable
              columnKeys={tableColumnKeys}
              data={tableData}
              serverPagination={{
                pageIndex,
                pageSize,
                hasMore: detail?.hasMore ?? false,
                loading,
                onNext: handleNext,
                onPrev: handlePrev,
                onPageSizeChange: handlePageSizeChange,
              }}
            />
            {!loading && gpsPoints.length > 0 && mapsConfig?.apiKey && (
              <GpsTrackMap points={gpsPoints} apiKey={mapsConfig.apiKey} mapId={mapsConfig.mapId} />
            )}
          </div>
        )}
      </div>
    </AppLayout>
  );
}
