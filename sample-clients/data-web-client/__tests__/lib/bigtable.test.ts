// Reset module registry between tests so the singleton is fresh
beforeEach(() => {
  jest.resetModules();
});

describe('getTelemetryTable', () => {
  it('returns a Table object pointing at the telemetry table for configured project and instance', () => {
    process.env.BIGTABLE_PROJECT_ID = 'test-project';
    process.env.BIGTABLE_INSTANCE_ID = 'test-instance';

    // Import fresh after env vars are set and modules are reset
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { getTelemetryTable } = require('@/lib/bigtable');
    const table = getTelemetryTable();

    // The SDK builds a full resource path from the env vars
    expect(table.name).toBe(
      'projects/test-project/instances/test-instance/tables/telemetry'
    );
  });
});
