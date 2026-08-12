# Changelog

`graph_db_sync` versions and ships with the rest of the repo, so the
repo-level [`CHANGELOG.md`](../../CHANGELOG.md) carries the detail. This
file records the release line.

## 0.0.1

Initial pre-release.

Push-only sync engine — WAL drain to remote targets, with durable
per-target high-water marks.

See the [repo changelog](../../CHANGELOG.md) for the full set of changes
in this development line, including the correctness fixes to node
tombstoning, edge-index maintenance, and WAL compaction.
