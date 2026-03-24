import { Bigtable } from '@google-cloud/bigtable';
import type { Table } from '@google-cloud/bigtable';

let _client: Bigtable | null = null;
let _table: Table | null = null;

function getClient(): Bigtable {
  if (!_client) {
    // projectId is intentionally optional here — when omitted the SDK resolves
    // the project from Application Default Credentials (ADC). This allows the
    // app to run on GKE without any explicit credential configuration.
    _client = new Bigtable({ projectId: process.env.BIGTABLE_PROJECT_ID });
  }
  return _client;
}

export function getTelemetryTable(): Table {
  if (!_table) {
    const instance = getClient().instance(process.env.BIGTABLE_INSTANCE_ID!);
    _table = instance.table('telemetry');
  }
  return _table;
}
