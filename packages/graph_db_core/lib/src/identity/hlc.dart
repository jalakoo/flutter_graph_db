import 'dart:math' as math;

/// Hybrid Logical Clock value (plan §6.3, §10).
///
/// Two fields: wall-clock [ms] (Unix epoch ms) + a tie-breaking
/// [counter]. **Represented as a record-shaped class — not packed into
/// a single 64-bit int — so it survives the web 53-bit limit** (plan
/// §6.3 explicitly calls this out).
///
/// Ordering: `(ms, counter)` lexicographic. Two HLCs are equal iff
/// both fields match.
class Hlc implements Comparable<Hlc> {
  final int ms;
  final int counter;

  const Hlc({required this.ms, required this.counter});

  /// Conventional starting state — wall-clock zero, counter zero.
  static const Hlc zero = Hlc(ms: 0, counter: 0);

  @override
  int compareTo(Hlc other) {
    final c = ms.compareTo(other.ms);
    return c != 0 ? c : counter.compareTo(other.counter);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.ms == ms && other.counter == counter;

  @override
  int get hashCode => Object.hash(ms, counter);

  @override
  String toString() => 'Hlc(ms: $ms, c: $counter)';
}

/// Mutable HLC clock per plan §6.3.
///
/// - [tick] for local events — bumps the clock past the wall-clock
///   reading or, if the wall clock has not advanced, bumps the
///   counter. Always produces an HLC strictly greater than [state]
///   before the call.
/// - [merge] for received events — bumps state past the max of
///   `(now, local.ms, remote.ms)` with the standard HLC counter rules.
///
/// The [now] supplier defaults to
/// `DateTime.now().millisecondsSinceEpoch`; pass an injected `now` for
/// deterministic tests.
class HlcClock {
  Hlc _state;
  final int Function() _now;

  HlcClock({Hlc initial = Hlc.zero, int Function()? now})
      : _state = initial,
        _now = now ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  Hlc get state => _state;

  /// Local event — advances the clock and returns the new HLC.
  Hlc tick() {
    final n = _now();
    if (n > _state.ms) {
      _state = Hlc(ms: n, counter: 0);
    } else {
      _state = Hlc(ms: _state.ms, counter: _state.counter + 1);
    }
    return _state;
  }

  /// Receive event carrying [remote]'s HLC. Returns the merged state,
  /// which is strictly greater than both [state] before the call and
  /// [remote] (so the merged HLC is safe to attach to any local event
  /// that causally follows the receive).
  Hlc merge(Hlc remote) {
    final n = _now();
    final maxMs = math.max(math.max(n, _state.ms), remote.ms);
    final int newCounter;
    if (maxMs == _state.ms && maxMs == remote.ms) {
      newCounter = math.max(_state.counter, remote.counter) + 1;
    } else if (maxMs == _state.ms) {
      newCounter = _state.counter + 1;
    } else if (maxMs == remote.ms) {
      newCounter = remote.counter + 1;
    } else {
      // Wall clock advanced past both — counter restarts.
      newCounter = 0;
    }
    _state = Hlc(ms: maxMs, counter: newCounter);
    return _state;
  }
}
