import { readdirSync } from 'fs';
import { join } from 'path';

import { config } from '../middleware';

// The middleware matcher is a hand-maintained copy of the route list. When
// /fleet was renamed to /telemetry the matcher kept the old name, so the pages
// that actually exist were no longer guarded — and nothing failed. This test is
// the comparison that was missing.

const APP_DIR = join(__dirname, '..', 'src', 'app');

// Routes that must stay reachable without a session.
const PUBLIC_ROUTES = ['/', '/auth/signin'];

/** Every route in src/app that renders a page, as a URL path. */
function pageRoutes(dir: string, prefix = ''): string[] {
  const routes: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      routes.push(...pageRoutes(join(dir, entry.name), `${prefix}/${entry.name}`));
    } else if (entry.name === 'page.tsx') {
      routes.push(prefix === '' ? '/' : prefix);
    }
  }
  return routes;
}

/** '/device/:path*' guards '/device' and everything below it. */
function isGuarded(route: string): boolean {
  return config.matcher.some((pattern) => {
    const base = pattern.replace('/:path*', '');
    return route === base || route.startsWith(`${base}/`);
  });
}

describe('middleware matcher', () => {
  const routes = pageRoutes(APP_DIR);

  it('finds the application routes', () => {
    expect(routes).toContain('/telemetry');
    expect(routes).toContain('/registry');
  });

  it.each(routes.filter((r) => !PUBLIC_ROUTES.includes(r)))(
    'guards %s',
    (route) => {
      expect(isGuarded(route)).toBe(true);
    },
  );

  it('does not guard a route that no longer exists', () => {
    for (const pattern of config.matcher) {
      const base = pattern.replace('/:path*', '');
      expect(routes.some((r) => r === base || r.startsWith(`${base}/`))).toBe(true);
    }
  });
});
