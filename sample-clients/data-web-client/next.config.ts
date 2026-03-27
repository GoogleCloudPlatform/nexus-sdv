import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  serverExternalPackages: ['@google-cloud/bigtable'],
};

export default nextConfig;
