'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useSession, signOut } from 'next-auth/react';

export default function Sidebar() {
  const pathname = usePathname();
  const { data: session } = useSession();

  const fleetActive =
    pathname === '/fleet' || pathname.startsWith('/device/');

  return (
    <aside className="w-56 flex flex-col bg-gray-900 text-white shrink-0">
      <div className="px-4 py-5 text-lg font-semibold tracking-tight border-b border-gray-700">
        Nexus SDV
      </div>

      <nav aria-label="Main navigation" className="flex-1 px-2 py-4">
        <Link
          href="/fleet"
          className={`flex items-center px-3 py-2 rounded text-sm ${
            fleetActive
              ? 'bg-gray-700 text-white'
              : 'text-gray-400 hover:bg-gray-800 hover:text-white'
          }`}
        >
          Fleet
        </Link>
      </nav>

      <div className="px-4 py-4 border-t border-gray-700 text-sm">
        <p className="text-gray-400 truncate mb-2">{session?.user?.email}</p>
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
