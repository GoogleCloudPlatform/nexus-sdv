import type { NextAuthOptions } from 'next-auth';
import KeycloakProvider from 'next-auth/providers/keycloak';

// Extend NextAuth types so session.groups is available project-wide.
declare module 'next-auth' {
  interface Session {
    groups: string[];
    roles: string[];
  }
}
declare module 'next-auth/jwt' {
  interface JWT {
    groups?: string[];
    roles?: string[];
  }
}

/** Realm role that sees every vehicle identity, not just its own group's. */
export const ADMIN_ROLE = 'nexus-admin';

export const authOptions: NextAuthOptions = {
  providers: [
    KeycloakProvider({
      clientId: process.env.KEYCLOAK_CLIENT_ID!,
      clientSecret: process.env.KEYCLOAK_CLIENT_SECRET!,
      issuer: process.env.KEYCLOAK_ISSUER!,
    }),
  ],
  pages: {
    signIn: '/auth/signin',
  },
  callbacks: {
    jwt({ token, profile }) {
      // profile is only present on first sign-in; persist groups into JWT.
      if (profile) {
        const p = profile as { groups?: string[]; realm_access?: { roles?: string[] } };
        token.groups = p.groups ?? [];
        // Realm roles reach the ID token through a dedicated protocol mapper —
        // Keycloak puts them in the access token by default, not here. The mapper
        // is created by keycloak-provision-fleet-user.sh.
        token.roles = p.realm_access?.roles ?? [];
      }
      return token;
    },
    session({ session, token }) {
      session.groups = token.groups ?? [];
      session.roles = token.roles ?? [];
      return session;
    },
  },
};
