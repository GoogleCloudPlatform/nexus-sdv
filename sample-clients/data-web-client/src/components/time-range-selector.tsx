'use client';
import type { TimeRange } from '@/types/telemetry';

const RANGES: TimeRange[] = ['1h', '6h', '24h', '7d'];

interface TimeRangeSelectorProps {
  value: TimeRange;
  onChange: (range: TimeRange) => void;
}

export default function TimeRangeSelector({ value, onChange }: TimeRangeSelectorProps) {
  return (
    <div className="flex gap-1">
      {RANGES.map((range) => (
        <button
          key={range}
          type="button"
          onClick={() => onChange(range)}
          className={`px-3 py-1 text-sm rounded ${
            value === range
              ? 'bg-blue-600 text-white'
              : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
          }`}
        >
          {range}
        </button>
      ))}
    </div>
  );
}
