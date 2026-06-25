'use client';

import { useEffect, useState } from 'react';

const STORAGE_KEY = 'scoringMessages';
const MAX_MESSAGES = 100;

/**
 * Subscribe to the scoring SSE stream and persist incoming messages to
 * sessionStorage so they survive page reloads within the same tab session.
 *
 * On mount the hook hydrates state from sessionStorage (if any), then opens
 * the EventSource. Every new message is prepended to the in-memory list AND
 * written back to sessionStorage in the same update, keeping the two in sync.
 */
export function useScoringMessages() {
  const [messages, setMessages] = useState<string[]>([]);

  // Hydrate from sessionStorage on mount. Wrapped in its own effect (rather
  // than a lazy useState initializer) to avoid SSR/hydration mismatches:
  // sessionStorage doesn't exist on the server, so the initial render uses
  // [] on both server and client; this effect then fills it in client-side.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    try {
      const raw = window.sessionStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw) as unknown;
        if (Array.isArray(parsed)) {
          // Trim on hydration too — protects against legacy entries that
          // pre-date the cap, or a manual edit of sessionStorage.
          setMessages(
            parsed
              .filter((m): m is string => typeof m === 'string')
              .slice(0, MAX_MESSAGES),
          );
        }
      }
    } catch {
      // Corrupted entry — ignore and start fresh.
    }
  }, []);

  // Open the SSE stream once on mount. Each message is prepended to state
  // and the same updated list is written to sessionStorage so a reload
  // restores exactly what was on screen.
  useEffect(() => {
    const source = new EventSource('/api/scoring/stream');
    source.onmessage = (e) => {
      setMessages((prev) => {
        // Newest message goes to index 0; cap the total at MAX_MESSAGES so
        // the array (and sessionStorage payload) can't grow unboundedly.
        const next = [e.data, ...prev].slice(0, MAX_MESSAGES);
        try {
          window.sessionStorage.setItem(STORAGE_KEY, JSON.stringify(next));
        } catch {
          // Quota exceeded or storage disabled — fall through; the in-memory
          // list still updates so the UI stays correct for this session.
        }
        return next;
      });
    };
    source.onerror = () => source.close();
    return () => source.close();
  }, []);

  return messages;
}
