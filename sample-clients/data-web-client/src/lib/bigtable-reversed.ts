import type { Row } from '@google-cloud/bigtable';
import { Transform } from 'stream';

// ---------------------------------------------------------------------------
// Why this file uses the raw gRPC request path instead of `Table.getRows()`
// ---------------------------------------------------------------------------
// The fleet UI needs telemetry rows displayed *newest first, globally* across
// pagination. BigTable row keys are `{deviceId}#{ISO8601_timestamp}`, so
// natural row-key order is oldest → newest. To deliver newest-first paging we
// need a reversed scan.
//
// The high-level `Table.getRows()` API in `@google-cloud/bigtable` v6.5.0 does
// NOT support reversed scans:
//   - `GetRowsOptions` has no `reversed` field in the type definitions.
//   - `createReadStreamInternal` (used by getRows) builds reqOpts and never
//     forwards a `reversed` flag, so passing it as an option is silently
//     dropped.
//
// Therefore we drop down to `bigtable.request({ method: 'readRows', ... })`
// — the same internal path the SDK uses — and build the request ourselves so
// we can set `reversed: true` directly on the gRPC ReadRowsRequest.
// ---------------------------------------------------------------------------

// Require these two internals via CommonJS rather than ES `import`:
//
//   1. `ChunkTransformer` is a named export of `@google-cloud/bigtable`, but
//      Next.js / Turbopack mangles the named binding when bundling for the
//      server runtime. The bundled output emitted `ChunkTransformer is not a
//      constructor` at runtime. Requiring the source module directly (the
//      bundler treats it as an opaque CJS module) preserves the constructor.
//
//   2. `pumpify` has no published TypeScript types in this version; `require`
//      avoids needing to ship our own ambient declaration.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { ChunkTransformer } = require('@google-cloud/bigtable/build/src/chunktransformer');
// eslint-disable-next-line @typescript-eslint/no-require-imports
const pumpify = require('pumpify');

/**
 * Read rows from BigTable in reversed order (newest first), using the raw
 * gRPC request path because the high-level SDK doesn't expose `reversed`.
 *
 * Range semantics:
 *   - BigTable always requires `start_key < end_key` in the proto, regardless
 *     of scan direction. `reversed: true` ONLY changes the iteration order;
 *     the server returns rows from `end` down to `start`.
 *   - We therefore always pass the range as (rangeLow → rangeHigh).
 *
 * Pagination:
 *   - The cursor stored client-side is the row key of the *last* row from the
 *     previous page — which, in a reversed scan, is the *oldest* row of that
 *     page.
 *   - For the next page we use that cursor as the EXCLUSIVE upper bound
 *     (`endKeyOpen`) so we don't re-emit it, and continue scanning backwards
 *     toward `rangeLow`.
 *   - For the first page (no cursor) `rangeHigh` is `now`, and we use
 *     `endKeyOpen` because `now` is never an exact row key anyway.
 */
export function readRowsReversed(
  // The bigtable Table type has surface we don't need to type strictly here;
  // we treat it as opaque and reach into `.bigtable.request` / `.row()`.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  table: any,
  rangeLow: string,
  rangeHigh: string,
  cursorExclusive: boolean,
  limit: number,
): Promise<Row[]> {
  return new Promise((resolve, reject) => {
    // Build a single RowRange in protobuf shape. `Buffer.from(...)` is the
    // wire encoding BigTable expects for key bytes.
    //
    // Note: both first-page and cursor-page use `endKeyOpen` (exclusive upper
    // bound). For the first page the upper bound is `now`, which is never an
    // exact row key. For cursor pages the upper bound is the cursor row,
    // which we MUST exclude or it would be returned twice across pages.
    // The `cursorExclusive` parameter is kept for clarity / future flexibility
    // even though both branches currently behave the same.
    const rowRange: Record<string, Buffer> = {
      startKeyClosed: Buffer.from(rangeLow),
      endKeyOpen: Buffer.from(rangeHigh),
    };
    void cursorExclusive; // documents intent; both paths use endKeyOpen today

    const reqOpts = {
      tableName: table.name,
      appProfileId: table.bigtable.appProfileId,
      rows: { rowRanges: [rowRange] },
      rowsLimit: limit,
      reversed: true, // <-- the whole reason we bypass Table.getRows()
    };

    // ---------------------------------------------------------------------
    // The `bigtable-features` metadata header
    // ---------------------------------------------------------------------
    // Even with `reversed: true` set, the BigTable *server* will reject the
    // request with `UNIMPLEMENTED: Client doesn't support reverse scans yet`
    // unless the client advertises support via the `bigtable-features`
    // gRPC metadata header.
    //
    // The header value is a websafe-base64 encoding of a serialized
    // `google.bigtable.v2.FeatureFlags` protobuf message. We need
    // `reverse_scans = true` (field number 1, bool / varint).
    //
    // Manual proto encoding for `{ reverse_scans: true }`:
    //   tag  = (field_number << 3) | wire_type
    //        = (1 << 3) | 0 (varint)
    //        = 0x08
    //   value = 1 = 0x01
    //   bytes = [0x08, 0x01]
    //   base64("\x08\x01") = "CAE="
    //
    // SDK v6.5.0 does NOT set this header automatically (newer versions of
    // the Go / Java clients do; the Node client lags). We inject it via
    // `gaxOpts.otherArgs.headers` — the v2 BigtableClient.readRows merges
    // these into the outgoing gRPC metadata.
    const gaxOpts = {
      otherArgs: {
        headers: { 'bigtable-features': 'CAE=' },
      },
    };

    // Server-streaming gRPC request. Returns a stream of `ReadRowsResponse`
    // protobuf messages, each carrying a batch of cell chunks. The chunks
    // need to be reassembled into row-shaped objects — that's what
    // ChunkTransformer is for.
    const requestStream = table.bigtable.request({
      client: 'BigtableClient',
      method: 'readRows',
      reqOpts,
      gaxOpts,
    });

    // ChunkTransformer turns the raw chunk stream into row data events. We
    // construct it the same way `createReadStreamInternal` does internally.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const chunkTransformer = new ChunkTransformer({ decode: true } as any);

    // ---------------------------------------------------------------------
    // Patch ChunkTransformer.validateNewRow to allow descending row keys.
    // ---------------------------------------------------------------------
    // ChunkTransformer was written for forward scans only. Its `validateNewRow`
    // checks that each new row key is strictly GREATER than the previous one,
    // and throws `TransformError: A row key must be strictly increasing`
    // otherwise. For a reversed scan, row keys arrive in strictly DECREASING
    // order, so the check fires on the second row.
    //
    // We can't disable just that one check via configuration — it has none.
    // We monkey-patch the instance method to temporarily clear `lastRowKey`
    // before delegating to the original validator, which makes the
    // less-than-or-equal-to comparison a no-op (`undefined` short-circuits).
    // All other validations (row already in progress, missing key, missing
    // family, reset on new row, etc.) still run normally.
    //
    // After validation, the original method sets `lastRowKey = newRowKey` as
    // part of normal processing. If for any reason it didn't, we restore the
    // saved value so subsequent dedup logic in the SDK continues to function.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const orig = (chunkTransformer as any).validateNewRow.bind(chunkTransformer);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (chunkTransformer as any).validateNewRow = function (chunk: any, newRowKey: any) {
      const saved = this.lastRowKey;
      this.lastRowKey = undefined;        // hide lastRowKey → ≤ check skipped
      orig(chunk, newRowKey);
      if (typeof this.lastRowKey === 'undefined') {
        this.lastRowKey = saved;          // restore only if orig didn't set it
      }
    };

    // Final transform: take the row-data events emitted by ChunkTransformer
    // and produce actual `Row` instances. This mirrors `toRowStream` inside
    // the SDK's `createReadStreamInternal`.
    const toRowStream = new Transform({
      objectMode: true,
      transform(rowData, _enc, next) {
        // ChunkTransformer also emits LAST_ROW_KEY_UPDATE control events for
        // resumable scans (these have an `eventType` field instead of row
        // data). We don't implement resumption, so just drop them.
        if (rowData.eventType !== undefined) {
          return next();
        }
        const row: Row = table.row(rowData.key);
        // The SDK populates `row.data` directly with the raw cell map; this
        // matches the shape the consuming code below expects.
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (row as any).data = rowData.data;
        next(null, row);
      },
    });

    // Pipe: gRPC stream → chunk reassembly → row construction → us.
    // pumpify.obj wires up object-mode piping plus error propagation across
    // the whole chain so a failure anywhere rejects the promise.
    const rows: Row[] = [];
    const pipeline = pumpify.obj(requestStream, chunkTransformer, toRowStream);

    pipeline.on('data', (row: Row) => rows.push(row));
    pipeline.on('end', () => resolve(rows));
    pipeline.on('error', (err: Error) => reject(err));
  });
}
