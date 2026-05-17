/// Persistent worker-isolate scaffolding.
///
/// A **single** worker isolate stays alive for the lifetime of the
/// database, receives immutable typed-data tasks, computes, and
/// replies — never blocking the main isolate's event loop. On web,
/// isolates do not exist; this module provides a synchronous
/// main-isolate fallback so the same call site works on both targets.
///
/// This file is the **plumbing only** — the merge fold, the CSR
/// payloads, and the `TransferableTypedData` packing are layered on
/// top (see `merge_protocol.dart` and `merge_coordinator.dart`).
library;

import 'dart:async';
import 'dart:isolate';

import '../platform.dart';

/// Sentinel message that asks the worker to close its inbox.
///
/// A simple `String` is intentional — strings are guaranteed cheap to
/// send across isolates and impossible to confuse with a payload type.
const String _kShutdown = '__graph_db_core::persistent_worker::shutdown__';

/// Envelope sent main -> worker. Carries the request payload and the
/// port the worker should reply on. Internal; callers see only
/// [PersistentWorker.send].
class _Envelope {
  _Envelope(this.payload, this.replyTo);

  final Object? payload;
  final SendPort replyTo;
}

/// Drives the loop **inside** a worker isolate.
///
/// Wires up the handshake, listens for [_Envelope] requests, casts
/// `payload` to [Req], calls [handle], and replies. Call exactly once
/// from the top-level function passed to [PersistentWorker.spawn].
///
/// ```dart
/// // Top-level (must be top-level for Isolate.spawn).
/// void myWorkerEntry(SendPort handshake) {
///   runPersistentWorkerLoop<MyReq, MyResp>(handshake, (req) => ...);
/// }
/// ```
///
/// [handle] runs synchronously inside the worker's event loop, one
/// request at a time. Throwing inside [handle] sends the exception
/// (as an `Object`) back over `replyTo`; callers can detect this with
/// `if (resp is Exception)` or by type-guarding [Resp].
void runPersistentWorkerLoop<Req, Resp>(
  SendPort handshake,
  Resp Function(Req req) handle,
) {
  final inbox = ReceivePort();
  handshake.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg == _kShutdown) {
      inbox.close();
      return;
    }
    final env = msg as _Envelope;
    try {
      final resp = handle(env.payload as Req);
      env.replyTo.send(resp);
    } catch (e, st) {
      // Send a structured failure rather than letting the isolate die
      // silently — the main side wraps this in `send`.
      env.replyTo.send(_WorkerError(e, st));
    }
  });
}

class _WorkerError {
  _WorkerError(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

/// Owns one long-lived background worker — or, on web, runs the handler
/// inline on the main isolate.
///
/// Use [spawn] to construct. Use [send] to issue a request and await
/// the response. Use [dispose] to tear the worker down.
class PersistentWorker<Req, Resp> {
  PersistentWorker._native(this._isolate, this._port)
      : _webHandler = null;

  PersistentWorker._web(Resp Function(Req) handler)
      : _isolate = null,
        _port = null,
        _webHandler = handler;

  final Isolate? _isolate;
  final SendPort? _port;
  final Resp Function(Req)? _webHandler;

  /// True when a real worker isolate is in use. False on web.
  bool get usesIsolate => _isolate != null;

  /// Spawns the worker.
  ///
  /// - On native: spawns an isolate at [entry], exchanges a handshake,
  ///   and returns a wired-up worker. [entry] must be a top-level (or
  ///   static) function — it cannot be a closure.
  /// - On web: no isolate is spawned. [webFallback] must be supplied;
  ///   each [send] invokes it synchronously on the main isolate and
  ///   wraps the result in a `Future`. Pass `null` to disable web
  ///   (calling [send] on web with no fallback throws).
  static Future<PersistentWorker<Req, Resp>> spawn<Req, Resp>(
    void Function(SendPort handshake) entry, {
    Resp Function(Req req)? webFallback,
  }) async {
    if (isWeb) {
      if (webFallback == null) {
        throw StateError(
          'PersistentWorker.spawn: running on web but no webFallback '
          'handler was provided. Either ship one, or do not call '
          'spawn() on web.',
        );
      }
      return PersistentWorker<Req, Resp>._web(webFallback);
    }
    final handshake = ReceivePort();
    final iso = await Isolate.spawn(entry, handshake.sendPort);
    final port = await handshake.first as SendPort;
    handshake.close();
    return PersistentWorker<Req, Resp>._native(iso, port);
  }

  /// Sends [request] and resolves with the response.
  ///
  /// Concurrent calls are allowed: each opens its own `ReceivePort` for
  /// the reply, so responses are routed by port identity, not by order.
  /// Inside the worker, [runPersistentWorkerLoop] processes one request
  /// at a time on the worker's event loop.
  Future<Resp> send(Req request) async {
    final webHandler = _webHandler;
    if (webHandler != null) {
      // Wrap in a microtask so callers always observe Future semantics
      // (`await` yields once), matching the native path's behaviour.
      return Future.microtask(() => webHandler(request));
    }
    final reply = ReceivePort();
    _port!.send(_Envelope(request, reply.sendPort));
    final raw = await reply.first;
    reply.close();
    if (raw is _WorkerError) {
      Error.throwWithStackTrace(raw.error, raw.stack);
    }
    return raw as Resp;
  }

  /// Tears the worker down. Safe to call once; subsequent [send]s will
  /// throw.
  Future<void> dispose() async {
    final iso = _isolate;
    if (iso != null) {
      _port!.send(_kShutdown);
      iso.kill(priority: Isolate.beforeNextEvent);
    }
  }
}
