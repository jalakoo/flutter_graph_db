import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

void main() {
  group('Hlc value class', () {
    test('equality + hashCode are value-based', () {
      const a = Hlc(ms: 100, counter: 3);
      const b = Hlc(ms: 100, counter: 3);
      const c = Hlc(ms: 100, counter: 4);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('compareTo orders by (ms, counter) lexicographic', () {
      const a = Hlc(ms: 100, counter: 0);
      const b = Hlc(ms: 100, counter: 1);
      const c = Hlc(ms: 101, counter: 0);
      expect(a.compareTo(a), 0);
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(c), lessThan(0));
      expect(a.compareTo(c), lessThan(0));
      expect(c.compareTo(a), greaterThan(0));
    });

    test('operator overloads agree with compareTo', () {
      const a = Hlc(ms: 100, counter: 0);
      const b = Hlc(ms: 100, counter: 1);
      expect(a < b, isTrue);
      expect(a <= b, isTrue);
      expect(b > a, isTrue);
      expect(b >= a, isTrue);
      expect(a >= a, isTrue);
      expect(a <= a, isTrue);
    });
  });

  group('HlcClock — tick', () {
    test('successive ticks are strictly ascending even within a ms', () {
      var fakeNow = 1000;
      final clock = HlcClock(now: () => fakeNow);
      final t1 = clock.tick();
      final t2 = clock.tick();
      final t3 = clock.tick();
      expect(t1 < t2, isTrue);
      expect(t2 < t3, isTrue);
      // All three landed in ms=1000 → counter bumped each time.
      expect(t1.ms, 1000);
      expect(t2.ms, 1000);
      expect(t3.ms, 1000);
      expect(t2.counter, t1.counter + 1);
      expect(t3.counter, t2.counter + 1);
    });

    test('a wall-clock advance resets the counter', () {
      var fakeNow = 1000;
      final clock = HlcClock(now: () => fakeNow);
      clock.tick(); // (1000, 0)
      clock.tick(); // (1000, 1)
      fakeNow = 1005;
      final t = clock.tick();
      expect(t, const Hlc(ms: 1005, counter: 0));
    });

    test('initial state defaults to Hlc.zero', () {
      final c = HlcClock();
      expect(c.state, Hlc.zero);
    });
  });

  group('HlcClock — merge', () {
    test('newer remote ms advances local; counter follows remote', () {
      var fakeNow = 100;
      final clock = HlcClock(initial: const Hlc(ms: 100, counter: 0), now: () => fakeNow);
      final merged = clock.merge(const Hlc(ms: 200, counter: 5));
      expect(merged.ms, 200);
      expect(merged.counter, 6); // remote.counter + 1
    });

    test('older remote ms keeps local ms and bumps local counter', () {
      var fakeNow = 200;
      final clock = HlcClock(initial: const Hlc(ms: 200, counter: 3), now: () => fakeNow);
      final merged = clock.merge(const Hlc(ms: 100, counter: 9));
      expect(merged.ms, 200);
      expect(merged.counter, 4); // local.counter + 1
    });

    test('equal ms on both sides + wall takes max counter + 1', () {
      var fakeNow = 100;
      final clock = HlcClock(initial: const Hlc(ms: 100, counter: 3), now: () => fakeNow);
      final merged = clock.merge(const Hlc(ms: 100, counter: 7));
      expect(merged.ms, 100);
      expect(merged.counter, 8); // max(3, 7) + 1
    });

    test('wall clock past both restarts counter at 0', () {
      var fakeNow = 500;
      final clock = HlcClock(initial: const Hlc(ms: 100, counter: 9), now: () => fakeNow);
      final merged = clock.merge(const Hlc(ms: 200, counter: 5));
      expect(merged, const Hlc(ms: 500, counter: 0));
    });

    test('merged HLC is strictly greater than both inputs', () {
      var fakeNow = 100;
      final clock = HlcClock(initial: const Hlc(ms: 200, counter: 0), now: () => fakeNow);
      final remote = const Hlc(ms: 200, counter: 0);
      final merged = clock.merge(remote);
      expect(merged > const Hlc(ms: 200, counter: 0), isTrue);
      expect(merged > remote, isTrue);
    });
  });
}
