import 'package:graph_db_core/graph_db_core.dart';

import 'codec/wal_codec.dart';
import 'wal_store.dart';

/// Frames + encodes a [SequencedWalOp] per the §6.1 schema and appends
/// it to the underlying [WalStore]. Thin wrapper — the codec does all
/// the work and the store handles durability.
class WalWriter {
  final WalStore store;
  final WalCodec _codec;

  WalWriter(this.store, {WalCodec codec = const WalCodec()})
      : _codec = codec;

  /// Encode + append. Calls through to the store's [append], honoring
  /// the per-call [durability] hint (plan §6.7).
  Future<void> append(
    SequencedWalOp op, {
    required Durability durability,
  }) async {
    final framed = _codec.encodeFramed(op);
    await store.append(framed, durability: durability);
  }
}
