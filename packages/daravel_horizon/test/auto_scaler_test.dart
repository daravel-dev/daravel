import 'dart:math';

import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

const high = QueueName('high');
const low = QueueName('default');

SupervisorPlan plan({
  BalanceStrategy balance = BalanceStrategy.auto,
  AutoScalingStrategy strategy = AutoScalingStrategy.time,
  int min = 1,
  int max = 10,
  int shift = 1,
  List<QueueName> queues = const [high, low],
}) => SupervisorPlan(
  name: const SupervisorName('s'),
  queues: queues,
  balance: balance,
  autoScalingStrategy: strategy,
  minProcesses: min,
  maxProcesses: max,
  balanceMaxShift: shift,
);

void main() {
  test('ewma: the first sample alone, then α·x + (1 − α)·x̂', () {
    expect(ewma(null, 10, 0.3), 10);
    expect(ewma(10, 20, 0.3), closeTo(13, 1e-9));
  });

  test('off: every worker on every queue', () {
    final d = decide(
      ScalingInput(
        plan: plan(balance: BalanceStrategy.off, max: 4),
        queues: const [],
      ),
      const ScalingState(),
    );
    expect((d.total, d.shared, d.reason), (4, 4, 'off'));
    expect(d.perQueue, isEmpty);
  });

  test('simple: maxProcesses split evenly, the rest to the first queue', () {
    final d = decide(
      ScalingInput(
        plan: plan(balance: BalanceStrategy.simple, max: 5),
        queues: const [],
      ),
      const ScalingState(),
    );
    expect(d.perQueue, {'high': 3, 'default': 2});
    expect(d.shared, 0);
  });

  group('auto (time)', () {
    test("Little's law: backlog over the target plus arrivals", () {
      // high: 120 jobs × 1 s / 60 s = 2, plus 3 jobs/s × 1 s = 3 → 5.
      final d = decide(
        ScalingInput(
          plan: plan(shift: 10),
          queues: const [
            QueueLoad(
              queue: high,
              size: 120,
              arrivalRate: 3,
              serviceTime: Duration(seconds: 1),
            ),
            QueueLoad(queue: low, size: 0),
          ],
        ),
        const ScalingState(workers: 1),
      );
      expect(d.total, 5);
      expect(d.perQueue, {'high': 5});
      expect(d.reason, 'scale-up');
    });

    test('moves at most balanceMaxShift per evaluation', () {
      var state = const ScalingState(workers: 1);
      final sizes = <int>[];
      for (var i = 0; i < 4; i++) {
        final d = decide(
          ScalingInput(
            plan: plan(shift: 2),
            queues: const [QueueLoad(queue: high, size: 600)],
          ),
          state,
        );
        sizes.add(d.total);
        state = d.state;
      }
      expect(sizes, [3, 5, 7, 9]);
    });

    test('scales down only after two calm evaluations', () {
      var state = const ScalingState(workers: 6);
      final reasons = <String>[];
      final sizes = <int>[];
      for (var i = 0; i < 4; i++) {
        final d = decide(
          ScalingInput(
            plan: plan(),
            queues: const [
              QueueLoad(queue: high, size: 0, oldestWait: Duration(seconds: 5)),
            ],
          ),
          state,
        );
        reasons.add(d.reason);
        sizes.add(d.total);
        state = d.state;
      }
      expect(reasons, ['wait-calm', 'scale-down', 'wait-calm', 'scale-down']);
      expect(sizes, [6, 5, 5, 4]);
    });

    test('a wait over half the target is not calm', () {
      final d = decide(
        ScalingInput(
          plan: plan(),
          queues: const [
            QueueLoad(queue: high, size: 0, oldestWait: Duration(seconds: 40)),
          ],
        ),
        const ScalingState(workers: 4, calm: 5),
      );
      expect((d.total, d.reason, d.state.calm), (4, 'wait-calm', 0));
    });

    test('minProcesses 0: an idle supervisor goes to zero', () {
      var state = const ScalingState(workers: 1);
      for (var i = 0; i < 2; i++) {
        state = decide(
          ScalingInput(
            plan: plan(min: 0),
            queues: const [QueueLoad(queue: high, size: 0)],
          ),
          state,
        ).state;
      }
      expect(state.workers, 0);
    });

    test('every queue with jobs gets a worker; the rest are shared', () {
      final d = decide(
        ScalingInput(
          plan: plan(min: 3, max: 3),
          queues: const [
            QueueLoad(queue: high, size: 1000),
            QueueLoad(queue: low, size: 1),
          ],
        ),
        const ScalingState(workers: 3),
      );
      expect(d.perQueue['default'], greaterThanOrEqualTo(1));
      expect(d.perQueue.values.fold(0, (a, b) => a + b) + d.shared, d.total);
    });

    test('rates are smoothed across evaluations', () {
      final first = decide(
        ScalingInput(
          plan: plan(),
          queues: const [
            QueueLoad(
              queue: high,
              size: 0,
              arrivalRate: 10,
              serviceTime: Duration(seconds: 2),
            ),
          ],
        ),
        const ScalingState(workers: 1),
      );
      final second = decide(
        ScalingInput(
          plan: plan(),
          queues: const [QueueLoad(queue: high, size: 0, arrivalRate: 0)],
        ),
        first.state,
      );
      expect(second.state.arrival['high'], closeTo(7, 1e-9));
      expect(second.state.service['high'], 2, reason: 'no sample: kept');
    });
  });

  test('auto (size): one worker per jobsPerProcess waiting jobs', () {
    final d = decide(
      ScalingInput(
        plan: plan(strategy: AutoScalingStrategy.size, shift: 10),
        queues: const [QueueLoad(queue: high, size: 250)],
        jobsPerProcess: 100,
      ),
      const ScalingState(workers: 1),
    );
    expect(d.total, 3);
  });

  test('property: 1 000 random inputs never leave [min, max] nor move '
      'more than balanceMaxShift', () {
    final random = Random(42);
    for (var i = 0; i < 1000; i++) {
      final min = random.nextInt(4);
      final max = min + 1 + random.nextInt(8);
      final shift = 1 + random.nextInt(3);
      final p = plan(
        min: min,
        max: max,
        shift: shift,
        strategy: random.nextBool()
            ? AutoScalingStrategy.time
            : AutoScalingStrategy.size,
      );
      final before = min + random.nextInt(max - min + 1);
      final state = ScalingState(
        workers: before,
        calm: random.nextInt(4),
        arrival: {'high': random.nextDouble() * 50},
        service: {'high': random.nextDouble() * 5},
      );
      final d = decide(
        ScalingInput(
          plan: p,
          queues: [
            for (final q in [high, low])
              QueueLoad(
                queue: q,
                size: random.nextInt(5000),
                oldestWait: Duration(seconds: random.nextInt(200)),
                arrivalRate: random.nextBool()
                    ? random.nextDouble() * 100
                    : null,
                serviceTime: random.nextBool()
                    ? Duration(milliseconds: random.nextInt(10000))
                    : null,
                targetWait: Duration(seconds: 1 + random.nextInt(120)),
              ),
          ],
          jobsPerProcess: 1 + random.nextInt(200),
        ),
        state,
      );
      expect(d.total, inInclusiveRange(min, max), reason: 'case $i');
      expect(
        (d.total - before).abs(),
        lessThanOrEqualTo(shift),
        reason: 'case $i',
      );
      expect(
        d.perQueue.values.fold(0, (a, b) => a + b) + d.shared,
        d.total,
        reason: 'case $i: every worker placed once',
      );
      expect(d.perQueue.values.every((n) => n > 0), isTrue);
    }
  });
}
