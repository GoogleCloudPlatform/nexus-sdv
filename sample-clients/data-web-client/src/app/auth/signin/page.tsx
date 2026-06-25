'use client';
import { signIn } from 'next-auth/react';

export default function SignInPage() {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50">
      <div className="text-center space-y-4">
        <h1 className="text-2xl font-bold text-gray-900">Nexus SDV</h1>
        <p className="text-gray-500">Sign in to access the dashboard</p>
        <button
          onClick={() => signIn('keycloak', { callbackUrl: '/fleet' })}
          className="px-6 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
        >
          Sign in
        </button>
      </div>
    </div>
  );
}
