import type { Config } from 'jest';
import nextJest from 'next/jest.js';

const createJestConfig = nextJest({ dir: './' });

const nextTransform = {
  '^.+\\.(js|jsx|ts|tsx|mjs)$':
    require.resolve('next/dist/build/swc/jest-transformer.js'),
};

const config: Config = {
  coverageProvider: 'v8',
  projects: [
    {
      displayName: 'node',
      testEnvironment: 'node',
      testMatch: [
        '<rootDir>/__tests__/*.test.ts',
        '<rootDir>/__tests__/lib/**/*.test.ts',
        '<rootDir>/__tests__/api/**/*.test.ts',
      ],
      moduleNameMapper: { '^@/(.*)$': '<rootDir>/src/$1' },
      transform: nextTransform,
    },
    {
      displayName: 'jsdom',
      testEnvironment: 'jsdom',
      testMatch: ['<rootDir>/__tests__/components/**/*.test.tsx'],
      // Static assets must come first: '@/assets/logo.png' also matches the alias
      // below, and Jest takes the first matching pattern. Without this mapping the
      // PNG reached the transformer and the suite failed to parse before a single
      // test ran.
      moduleNameMapper: {
        '\\.(png|jpe?g|gif|webp|avif|ico|bmp|svg)$': '<rootDir>/__mocks__/fileMock.js',
        '^@/(.*)$': '<rootDir>/src/$1',
      },
      setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
      transform: nextTransform,
    },
  ],
};

export default createJestConfig(config);
