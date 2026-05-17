import 'package:graph_db_core/graph_db_core.dart';

import 'codec/wal_codec.dart';
import 'wal_store.dart';

/// Streams [SequencedWalOp]s out of a [WalStore]. Implements the /// recovery contract: bad checksum or truncated frame terminates the
/// scan; everything past the first bad entry is discarded silently
/// (the caller treats anything not yielded as never having been
/// written).
class WalReader {
  final WalStore store;
  final WalCodec _codec;

  WalReader(this.store, {WalCodec codec = const WalCodec()})
      : _codec = codec;

  /// Yields every committed [SequencedWalOp] starting at [fromOffset].
  ///
  /// The caller then routes each op through `apply(state, op,
  /// recovery: true)` — the recovery applicator writes the
  /// CSR directly without going through the delta overlay.
  Stream<SequencedWalOp> replay({int fromOffset = 0}) async* {
    final decoder = WalDecoder(_codec);
    await for (final chunk in store.read(fromOffset: fromOffset)) {
      for (final op in decoder.consume(chunk)) {
        yield op;
      }
      if (decoder.terminated) return;
    }
  }
}
