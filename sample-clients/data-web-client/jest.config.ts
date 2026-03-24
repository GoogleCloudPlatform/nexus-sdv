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
      moduleNameMapper: { '^@/(.*)$': '<rootDir>/src/$1' },
      setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
      transform: nextTransform,
    },
  ],
};

export default createJestConfig(config);
