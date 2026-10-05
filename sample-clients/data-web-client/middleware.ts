export { default } from 'next-auth/middleware';

// Every page route that needs a session. Keep in sync with src/app — the
// matcher is a hand-maintained copy of the route list and nothing fails when
// the two drift apart, which is how /fleet survived its rename to /telemetry.
// __tests__/middleware.test.ts compares the two.
export const config = {
  matcher: ['/telemetry/:path*', '/registry/:path*', '/device/:path*'],
};
