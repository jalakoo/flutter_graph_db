import 'dart:async';
import 'dart:developer' as developer;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'latency.dart';

/// A connection to this process's own VM service, used to observe garbage
/// collections. Both fields are null when the service is not enabled
/// (i.e. AOT, or `dart run` without `--enable-vm-service`). [gcEvents]
/// is a live running count of GC events seen.
class SelfConnection {
  final VmService? service;
  final String? isolateId;
  int gcEvents = 0;

  SelfConnection(this.service, this.isolateId);

  bool get available => service != null && isolateId != null;
}

/// Connects to this process's own VM service and subscribes to the GC
/// event stream. Degrades gracefully (returns an unavailable connection)
/// when the process was started without `--enable-vm-service`.
Future<SelfConnection> connectSelf() async {
  try {
    final info = await developer.Service.getInfo();
    final server = info.serverUri;
    if (server == null) return SelfConnection(null, null);

    final ws = server.replace(scheme: 'ws').resolve('ws');
    final service = await vmServiceConnectUri(ws.toString());
    final vm = await service.getVM();
    final isolates = vm.isolates;
    final id =
        (isolates != null && isolates.isNotEmpty) ? isolates.first.id : null;
    final conn = SelfConnection(service, id);

    try {
      await service.streamListen('GC');
      service.onGCEvent.listen((event) {
        if (event.isolate?.id == id) conn.gcEvents++;
      });
    } catch (_) {
      // GC stream unavailable — connection still usable, just no GC signal.
    }
    return conn;
  } catch (_) {
    return SelfConnection(null, null);
  }
}

/// Runs [op] [reps] times and returns the mean number of garbage
/// collections triggered per op.
///
/// `instancesAccumulated` from the allocation profiler is unreliable for
/// young-dying objects (the scavenger reclaims them before they show up).
/// GC frequency *is* driven by young-dying garbage, is version-stable,
/// and answers the spike's binary question directly: a value at the
/// noise floor (~0) means the inner loop is allocation-free; a clearly
/// non-zero value means it is not.
///
/// Returns `double.nan` when the VM service is not available.
Future<double> measureGcPerOp(
  SelfConnection conn,
  int reps,
  int Function() op,
) async {
  if (!conn.available) return double.nan;
  final service = conn.service!;
  final isolateId = conn.isolateId!;

  // Warm the op so one-time JIT/class-registration allocation does not
  // get attributed to the measured window.
  for (var i = 0; i < 8; i++) {
    blackhole ^= op();
  }

  // Clean slate, then let the gc:true collection's own event flush.
  await service.getAllocationProfile(isolateId, reset: true, gc: true);
  await service.getVersion();
  await Future<void>.delayed(const Duration(milliseconds: 10));

  final before = conn.gcEvents;
  var sink = 0;
  for (var i = 0; i < reps; i++) {
    sink ^= op();
  }
  blackhole ^= sink;

  // Round-trip + settle so buffered GC events arrive over the websocket.
  await service.getVersion();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final after = conn.gcEvents;

  return (after - before) / reps;
}
