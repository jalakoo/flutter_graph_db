import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

/// The single port between the engine and durable storage.
///
/// **Byte-range oriented, not WalOp-oriented.** Framing (length-prefix +
/// xxHash64 checksum) and CBOR encoding live *above* this port
/// in `graph_db_wal`'s codec layer — that is what makes an
/// `EncryptedWalStore` decorator possible without it ever seeing a
/// [WalOp].
///
/// **Adapters**:
/// - In-memory ([InMemoryWalStore]) — used in tests, on web, and as the
///   in-memory `WalStore` fixture for the integration suite.
/// - `dart:io` `RandomAccessFile` (`package:graph_db_wal/io_wal_store.dart`,
///   native only) — the default for iOS / Android / desktop.
/// - IndexedDB — lands when the web target is validated.
abstract class WalStore {
  /// Appends raw [bytes] to the log.
  ///
  /// The caller frames the payload (length-prefix + checksum) above this
  /// port. [durability] is the per-call hint; the implementation
  /// honours `fsync` immediately and defers `group` / `periodic` /
  /// `none` to the engine-level batching policy.
  Future<void> append(Uint8List bytes, {required Durability durability});

  /// Replays every byte previously written, starting at [fromOffset]
  /// (default 0). Chunked at whatever boundary the implementation finds
  /// convenient (whole segments for the io adapter, whole individual
  /// appends for the in-memory adapter). The caller re-assembles frames
  /// by walking the length-prefixes.
  Stream<Uint8List> read({int fromOffset = 0});

  /// Total bytes written so far — equals the byte offset the next
  /// append will land at.
  int get length;

  /// Truncates the log so every byte before [upToOffset] becomes
  /// unrecoverable. Implementations may round to segment boundaries
  /// — the actual truncated amount may be less than requested.
  /// Returns the byte offset *after* which data is retained.
  Future<int> truncate({required int upToOffset});

  /// Force any in-flight bytes to durable storage. No-op on adapters
  /// without a kernel buffer (e.g. [InMemoryWalStore]).
  Future<void> sync();

  /// Closes the store. After this, all operations throw [StateError].
  Future<void> close();
}
