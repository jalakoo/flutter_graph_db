# Changelog

`flutter_graph_db` versions and ships with the rest of the repo, so the
repo-level [`CHANGELOG.md`](../../CHANGELOG.md) carries the detail. This
file records the release line.

## 0.0.1

Initial pre-release.

Umbrella package — re-exports `graph_db_core`, `graph_db_wal`, and
`graph_db_gql` so one dependency and one import cover engine +
persistence + query.

See the [repo changelog](../../CHANGELOG.md) for the full set of changes
in this development line, including the correctness fixes to node
tombstoning, edge-index maintenance, and WAL compaction.
