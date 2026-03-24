import { getTelemetryTable } from '@/lib/bigtable';

describe('getTelemetryTable', () => {
  it('returns a Table object with the telemetry table name', () => {
    process.env.BIGTABLE_PROJECT_ID = 'test-project';
    process.env.BIGTABLE_INSTANCE_ID = 'test-instance';

    const table = getTelemetryTable();

    // The SDK Table object exposes its name as a string
    expect(table.name).toContain('telemetry');
  });
});
