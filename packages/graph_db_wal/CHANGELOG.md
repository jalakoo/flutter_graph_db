# Changelog

`graph_db_wal` versions and ships with the rest of the repo, so the
repo-level [`CHANGELOG.md`](../../CHANGELOG.md) carries the detail. This
file records the release line.

## 0.0.1

Initial pre-release.

WAL schema, CBOR codec, recovery, checkpointing, and the
`WalStore` / `SnapshotStore` ports with in-memory, native, and
IndexedDB adapters.

See the [repo changelog](../../CHANGELOG.md) for the full set of changes
in this development line, including the correctness fixes to node
tombstoning, edge-index maintenance, and WAL compaction.
