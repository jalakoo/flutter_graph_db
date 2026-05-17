# graph_db_wal

WAL persistence layer for `graph_db_core` — write-ahead log schema,
CBOR + length-prefix codec with xxHash64 per-record checksum, two-pass
redo-with-commit recovery, snapshot codec round-trip, and the
byte-range `WalStore` port.

Most consumers depend on the [`flutter_graph_db`](../flutter_graph_db)
umbrella and get this package transitively. Depend on it directly when
you need the platform-specific store adapters or finer-grained
durability control.

## Contents

- [Adapters](#adapters)
- [Quick reference](#quick-reference)
- [Snapshot + compact cycle](#snapshot--compact-cycle)

## Adapters

The `WalStore` interface is byte-range oriented — framing lives above
it, so any decorator (encryption, compression, network) can wrap a
store without seeing CBOR records.

| Adapter | Import | When to use |
|---|---|---|
| `InMemoryWalStore` | `package:graph_db_wal/graph_db_wal.dart` | tests, RAM-only mode, fixtures |
| `SegmentedInMemoryWalStore` | `package:graph_db_wal/graph_db_wal.dart` | tests that need segment-aligned truncate behaviour |
| `IoWalStore` | `package:graph_db_wal/io_wal_store.dart` (native only) | iOS / Android / macOS / Windows / Linux file persistence |
| `IndexedDbWalStore` | `package:graph_db_wal/indexeddb_wal_store.dart` (web only) | browser persistence via IndexedDB |

The native and web adapters live behind separate imports so a web
build keeps `dart:io` out of its dependency cone (and vice versa).

## Quick reference

```dart
import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:graph_db_wal/io_wal_store.dart';

Future<GraphDb> open(String path) async {
  final store = await IoWalStore.open(path);
  // Replays any prior session's WAL automatically; returns a ready
  // GraphDb whose every commit goes through the WAL.
  return openWalBackedGraphDb(store: store);
}
```

Per-call durability is controlled by the `Durability` enum on
`runTransaction`:

| Mode | Behaviour |
|---|---|
| `Durability.none` | no flush, no fsync — fastest, durable only after process flush |
| `Durability.group` | batched flush via the engine's group-commit window |
| `Durability.periodic` | flushed on a timer (configurable) |
| `Durability.fsync` | flushed + fsync'd before the future resolves |

## Snapshot + compact cycle

The `encodeSnapshot` / `decodeSnapshot` codec in `graph_db_core` pairs
with `compactToCurrentTip` here so the WAL doesn't grow unbounded.

```dart
db.state.mergeNow(); // codec invariant: overlay must be empty
final snap = encodeSnapshot(db.state);
await File('graph.snapshot').writeAsBytes(snap.bytes);
await compactToCurrentTip(store: store);
```

On next launch, restore the snapshot then let recovery replay any WAL
bytes appended after it:

```dart
final snapBytes = await File('graph.snapshot').readAsBytes();
final db = await openWalBackedGraphDb(
  store: store,
  snapshot: snapBytes,
);
```

The cycle is identical on every platform — only the `WalStore`
implementation differs.
