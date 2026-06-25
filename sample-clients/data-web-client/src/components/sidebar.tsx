'use client';
import Link from 'next/link';
import Image from 'next/image';
import { usePathname } from 'next/navigation';
import { useSession, signOut } from 'next-auth/react';
import { useScoringMessages } from '@/hooks/useScoringMessages';
import logo from '@/assets/logo.GlIrfdpi.png';

export default function Sidebar() {
  const pathname = usePathname();
  const { data: session } = useSession();
  const messages = useScoringMessages();

  const fleetActive =
    pathname === '/fleet' || pathname.startsWith('/device/');

  return (
    <aside className="w-56 flex flex-col bg-gray-900 text-white shrink-0">
      <div id="nexuslogo" className="px-2 py-1 flex items-center gap-3 border-b border-gray-700">
        <Image src={logo} alt="Nexus SDV logo" className="w-auto shrink-0" style={{ height: '3.5rem' }} />
        <span className="text-2xl font-semibold tracking-tight" style={{ fontSize: '1.5rem', color: '#b2c7ff' }}>Nexus SDV</span>
      </div>

      <nav aria-label="Main navigation" className="flex-1 px-2 py-1">
        <Link
          href="/fleet"
          className={`flex items-center px-3 py-2 rounded text-sm ${
            fleetActive
              ? 'bg-gray-700 text-white'
              : 'hover:bg-gray-800 hover:text-white'
          }`}
          style={fleetActive ? {} : { color: '#ffffff' }}
        >
          Fleet
        </Link>
      </nav>

      <div id="scoremessages" className="px-4 py-4 border-t border-gray-700">
        <p className="text-xs font-semibold uppercase mb-2" style={{ color: '#ffffff' }}>
          Scoring Events
        </p>
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
          className="w-full h-96 bg-gray-800 text-xs font-mono rounded p-2 resize-none overflow-y-auto border border-gray-700 focus:outline-none"
          style={{ color: '#ffffff' }}
          placeholder="No events yet…"
        />
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
