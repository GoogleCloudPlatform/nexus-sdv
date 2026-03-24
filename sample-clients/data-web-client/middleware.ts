export { default } from 'next-auth/middleware';

export const config = {
  matcher: ['/fleet/:path*', '/device/:path*'],
};
