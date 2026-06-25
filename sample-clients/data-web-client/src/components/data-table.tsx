'use client';
import { useMemo } from 'react';
import {
  useReactTable,
  getCoreRowModel,
  getPaginationRowModel,
  flexRender,
  createColumnHelper,
} from '@tanstack/react-table';

export interface ServerPaginationProps {
  pageIndex: number;
  pageSize: number;
  hasMore: boolean;
  loading: boolean;
  onNext: () => void;
  onPrev: () => void;
  onPageSizeChange: (size: number) => void;
}

interface DataTableProps {
  columnKeys: string[];
  data: Record<string, string>[];
  onRowClick?: (row: Record<string, string>) => void;
  serverPagination?: ServerPaginationProps;
}

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];
const DEFAULT_PAGE_SIZE = 25;

function stripFamily(key: string): string {
  const colon = key.indexOf(':');
  return colon > -1 ? key.slice(colon + 1) : key;
}

const columnHelper = createColumnHelper<Record<string, string>>();

export default function DataTable({ columnKeys, data, onRowClick, serverPagination }: DataTableProps) {
  const columns = useMemo(
    () =>
      columnKeys.map((key) =>
        columnHelper.accessor((row) => { const v = row[key]; return (!v || v === 'null') ? '---' : v; }, {
          id: key,
          header: stripFamily(key),
        })
      ),
    [columnKeys]
  );

  const table = useReactTable({
    data,
    columns,
    getCoreRowModel: getCoreRowModel(),
    ...(serverPagination
      ? { manualPagination: true }
      : {
          getPaginationRowModel: getPaginationRowModel(),
          initialState: { pagination: { pageSize: DEFAULT_PAGE_SIZE, pageIndex: 0 } },
        }),
  });

  // Client-side pagination state
  const clientState = serverPagination ? null : table.getState().pagination;
  const pageSize = serverPagination ? serverPagination.pageSize : (clientState?.pageSize ?? DEFAULT_PAGE_SIZE);
  const pageIndex = serverPagination ? serverPagination.pageIndex : (clientState?.pageIndex ?? 0);
  const totalRows = data.length;
  const firstRow = pageIndex * pageSize + 1;
  const lastRow = serverPagination
    ? pageIndex * pageSize + data.length
    : Math.min((pageIndex + 1) * pageSize, totalRows);

  const canPrev = serverPagination ? pageIndex > 0 : table.getCanPreviousPage();
  const canNext = serverPagination ? serverPagination.hasMore : table.getCanNextPage();

  function handlePrev() {
    if (serverPagination) serverPagination.onPrev();
    else table.previousPage();
  }

  function handleNext() {
    if (serverPagination) serverPagination.onNext();
    else table.nextPage();
  }

  function handleFirst() {
    if (!serverPagination) table.setPageIndex(0);
  }

  function handleLast() {
    if (!serverPagination) table.setPageIndex(table.getPageCount() - 1);
  }

  function handlePageSizeChange(size: number) {
    if (serverPagination) {
      serverPagination.onPageSizeChange(size);
    } else {
      table.setPageSize(size);
      table.setPageIndex(0);
    }
  }

  return (
    <div className="flex flex-col rounded border border-gray-200 overflow-hidden">
      {/* Fixed-height scrollable body with sticky header */}
      <div className="overflow-auto" style={{ maxHeight: '360px' }}>
        <table className="w-full text-sm">
          <thead className="bg-gray-50 sticky top-0 z-10">
            {table.getHeaderGroups().map((headerGroup) => (
              <tr key={headerGroup.id}>
                {headerGroup.headers.map((header) => (
                  <th
                    key={header.id}
                    className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider border-b border-gray-200"
                  >
                    {flexRender(header.column.columnDef.header, header.getContext())}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white">
            {serverPagination?.loading ? (
              <tr>
                <td colSpan={columnKeys.length} className="px-4 py-6 text-center text-gray-400">
                  Loading…
                </td>
              </tr>
            ) : (
              table.getRowModel().rows.map((row) => (
                <tr
                  key={row.id}
                  onClick={() => onRowClick?.(row.original)}
                  onKeyDown={(e) => {
                    if (onRowClick && (e.key === 'Enter' || e.key === ' ')) {
                      e.preventDefault();
                      onRowClick(row.original);
                    }
                  }}
                  tabIndex={onRowClick ? 0 : undefined}
                  className={onRowClick ? 'cursor-pointer hover:bg-gray-50' : ''}
                >
                  {row.getVisibleCells().map((cell) => (
                    <td key={cell.id} className="px-4 py-2 text-gray-700 whitespace-nowrap">
                      {flexRender(cell.column.columnDef.cell, cell.getContext())}
                    </td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Pagination controls */}
      <div className="flex items-center justify-between px-4 py-2 border-t border-gray-200 bg-gray-50 text-sm text-gray-600">
        <div className="flex items-center gap-2">
          <span>Rows per page:</span>
          <select
            value={pageSize}
            onChange={(e) => handlePageSizeChange(Number(e.target.value))}
            className="border border-gray-300 rounded px-1 py-0.5 text-sm bg-white"
          >
            {PAGE_SIZE_OPTIONS.map((n) => (
              <option key={n} value={n}>{n}</option>
            ))}
          </select>
        </div>

        <div className="flex items-center gap-3">
          <span>
            {serverPagination
              ? `${data.length === 0 ? '0' : `${firstRow}–${lastRow}`}${serverPagination.hasMore ? '+' : ''}`
              : (totalRows === 0 ? '0' : `${firstRow}–${lastRow} of ${totalRows}`)
            }
          </span>
          <div className="flex items-center gap-1">
            {!serverPagination && (
              <button
                onClick={handleFirst}
                disabled={!canPrev}
                className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-100 disabled:cursor-not-allowed"
                aria-label="First page"
              >«</button>
            )}
            <button
              onClick={handlePrev}
              disabled={!canPrev}
              className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-100 disabled:cursor-not-allowed"
              aria-label="Previous page"
            >‹</button>
            <button
              onClick={handleNext}
              disabled={!canNext}
              className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-100 disabled:cursor-not-allowed"
              aria-label="Next page"
            >›</button>
            {!serverPagination && (
              <button
                onClick={handleLast}
                disabled={!canNext}
                className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-100 disabled:cursor-not-allowed"
                aria-label="Last page"
              >»</button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
