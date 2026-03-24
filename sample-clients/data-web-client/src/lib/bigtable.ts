import { Bigtable } from '@google-cloud/bigtable';

let _client: Bigtable | null = null;

function getClient(): Bigtable {
  if (!_client) {
    _client = new Bigtable({ projectId: process.env.BIGTABLE_PROJECT_ID });
  }
  return _client;
}

export function getTelemetryTable() {
  const instance = getClient().instance(process.env.BIGTABLE_INSTANCE_ID!);
  return instance.table('telemetry');
}
