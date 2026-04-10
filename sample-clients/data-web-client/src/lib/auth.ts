import type { NextAuthOptions } from 'next-auth';
import KeycloakProvider from 'next-auth/providers/keycloak';

// Extend NextAuth types so session.groups is available project-wide.
declare module 'next-auth' {
  interface Session {
    groups: string[];
  }
}
declare module 'next-auth/jwt' {
  interface JWT {
    groups?: string[];
  }
}

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
        token.groups = (profile as { groups?: string[] }).groups ?? [];
      }
      return token;
    },
    session({ session, token }) {
      session.groups = token.groups ?? [];
      return session;
    },
  },
};
