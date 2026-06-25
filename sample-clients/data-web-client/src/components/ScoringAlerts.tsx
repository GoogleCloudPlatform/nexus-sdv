'use client';

import { useEffect } from 'react';

export function ScoringAlerts() {
  useEffect(() => {
    const source = new EventSource('/api/scoring/stream');
    source.onmessage = (e) => {
      alert(`scoring event:\n${e.data}`);
    };
    source.onerror = () => source.close();
    return () => source.close();
  }, []);

  return null;
}
