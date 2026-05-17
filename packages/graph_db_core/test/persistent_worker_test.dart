@TestOn('vm')
library;

import 'dart:isolate';

import 'package:graph_db_core/src/isolate/persistent_worker.dart';
import 'package:test/test.dart';

// Top-level worker entry points (Isolate.spawn cannot take closures).
void _echoEntry(SendPort handshake) {
  runPersistentWorkerLoop<int, int>(handshake, (n) => n);
}

void _doubleEntry(SendPort handshake) {
  runPersistentWorkerLoop<int, int>(handshake, (n) => n * 2);
}

void _throwingEntry(SendPort handshake) {
  runPersistentWorkerLoop<int, int>(handshake, (n) {
    if (n < 0) throw StateError('negative input: $n');
    return n + 1;
  });
}

// Records every request order, then sleeps for a few ms to widen the
// window where requests can be in-flight.
void _slowDoubleEntry(SendPort handshake) {
  runPersistentWorkerLoop<int, int>(handshake, (n) {
    final until = DateTime.now().add(const Duration(milliseconds: 3));
    while (DateTime.now().isBefore(until)) {}
    return n * 2;
  });
}

void main() {
  test('round-trips a single request', () async {
    final w = await PersistentWorker.spawn<int, int>(_echoEntry);
    expect(w.usesIsolate, isTrue);
    expect(await w.send(42), 42);
    await w.dispose();
  });

  test('handles many concurrent in-flight requests', () async {
    final w = await PersistentWorker.spawn<int, int>(_slowDoubleEntry);
    // Fire 8 requests without awaiting; each has its own reply port.
    final futures = [for (var i = 0; i < 8; i++) w.send(i)];
    final results = await Future.wait(futures);
    expect(results, [0, 2, 4, 6, 8, 10, 12, 14]);
    await w.dispose();
  });

  test('handler exception is rethrown on the caller side', () async {
    final w = await PersistentWorker.spawn<int, int>(_throwingEntry);
    expect(await w.send(5), 6);
    expect(
      () => w.send(-1),
      throwsA(isA<StateError>()),
    );
    // Worker remains usable after a thrown request.
    expect(await w.send(10), 11);
    await w.dispose();
  });

  test('isolate stays alive across many sequential requests', () async {
    final w = await PersistentWorker.spawn<int, int>(_doubleEntry);
    for (var i = 0; i < 64; i++) {
      expect(await w.send(i), i * 2);
    }
    await w.dispose();
  });
}
