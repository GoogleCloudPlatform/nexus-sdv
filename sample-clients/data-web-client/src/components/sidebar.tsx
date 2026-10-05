'use client';
import Link from 'next/link';
import Image from 'next/image';
import { useState } from 'react';
import { usePathname } from 'next/navigation';
import { useSession, signOut } from 'next-auth/react';
import { useScoringMessages } from '@/hooks/useScoringMessages';
import logo from '@/assets/logo.GlIrfdpi.png';

const NAV = [
  { href: '/registry', label: 'Vehicle Registry', isActive: (p: string) => p.startsWith('/registry') },
  // The device detail page belongs to Telemetry, so it keeps that entry active.
  { href: '/telemetry', label: 'Telemetry', isActive: (p: string) => p === '/telemetry' || p.startsWith('/device/') },
];

export default function Sidebar() {
  const pathname = usePathname();
  const { data: session } = useSession();
  const messages = useScoringMessages();
  // Collapsed by default: scoring events are a sample-service demo and were
  // taking up most of the sidebar. Messages keep arriving either way — the hook
  // subscribes regardless of whether the panel is shown.
  const [showScoring, setShowScoring] = useState(false);

  return (
    <aside className="w-56 flex flex-col bg-gray-900 text-white shrink-0">
      <div id="nexuslogo" className="px-2 py-1 flex items-center gap-3 border-b border-gray-700">
        <Image src={logo} alt="Nexus SDV logo" className="w-auto shrink-0" style={{ height: '3.5rem' }} />
        <span className="text-2xl font-semibold tracking-tight" style={{ fontSize: '1.5rem', color: '#b2c7ff' }}>Nexus SDV</span>
      </div>

      <nav aria-label="Main navigation" className="flex-1 px-2 py-1 space-y-1">
        {NAV.map(({ href, label, isActive }) => {
          const active = isActive(pathname);
          return (
            <Link
              key={href}
              href={href}
              className={`flex items-center px-3 py-2 rounded text-sm ${
                active ? 'bg-gray-700 text-white' : 'hover:bg-gray-800 hover:text-white'
              }`}
              style={active ? {} : { color: '#ffffff' }}
            >
              {label}
            </Link>
          );
        })}
      </nav>

      <div id="scoremessages" className="px-4 py-3 border-t border-gray-700">
        <button
          type="button"
          onClick={() => setShowScoring((v) => !v)}
          aria-expanded={showScoring}
          className="w-full flex items-center justify-between text-xs font-semibold uppercase hover:text-gray-300"
          style={{ color: '#ffffff' }}
        >
          <span>Scoring Events{messages.length > 0 && ` (${messages.length})`}</span>
          <span aria-hidden="true">{showScoring ? '▾' : '▸'}</span>
        </button>

        {showScoring && (
          <textarea
            readOnly
            value={messages.map((raw) => {
              try {
                const { vehicle, score, message } = JSON.parse(raw);
                return `${vehicle} - ${score} - ${message}`;
              } catch {
                return raw;
              }
            }).join('\n')}
            className="mt-2 w-full h-96 bg-gray-800 text-xs font-mono rounded p-2 resize-none overflow-y-auto border border-gray-700 focus:outline-none"
            style={{ color: '#ffffff' }}
            placeholder="No events yet…"
          />
        )}
      </div>

      <div className="px-4 py-4 border-t border-gray-700 text-sm">
        <p className="truncate mb-2" style={{ color: '#ffffff' }}>{session?.user?.email}</p>
        <button
          type="button"
          onClick={() => signOut({ callbackUrl: '/auth/signin' })}
          className="text-gray-500 hover:text-white"
        >
          Sign out
        </button>
      </div>
    </aside>
  );
}
