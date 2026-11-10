// The coordinator's ceiling (Blueprint #141, K0 §3.11, items 1, 3, 4): one
// standard coordinator in this isolate, N client isolates calling it the
// way the framework's stores do (ProcessRateLimitStore, ProcessStore,
// Broadcaster over a RemoteCoordinatorChannel), no library change.
//
//   dart compile exe bin/coordinator_ceiling.dart -o build/coordinator_ceiling
//   build/coordinator_ceiling --duration=5 --clients=1,4,8,16 [--json]
//
// 1. ceiling: operations and coordinator messages per second, p50/p99
//    round trip, for a rate limit attempt without lease, a lock (acquire
//    and release), a cache get and a publish, at each client count;
// 3. saturation: p50/p99 of a rate limit attempt from one probe isolate,
//    alone and while flood isolates publish as fast as they can;
// 4. lease: for limits of 60, 1 000 and 10 000 per minute, attempts from 4
//    and 16 isolates in one window: how many were allowed past the limit,
//    and coordinator messages per decision.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:daravel/daravel.dart';

/// Latency buckets: 1 µs × 1.1^i, enough for 1 µs to over 10 s.
const int bucketCount = 180;

int bucketOf(int micros) {
  if (micros <= 1) {
    return 0;
  }
  final i = (log(micros) / log(1.1)).floor();
  return i >= bucketCount ? bucketCount - 1 : i;
}

double bucketMicros(int i) => pow(1.1, i + 1).toDouble();

/// What one client isolate is asked to do.
final class ClientJob {
  const ClientJob({
    required this.coordinator,
    required this.reply,
    required this.op,
    required this.index,
    required this.millis,
    required this.inFlight,
    this.limit = 0,
  });

  final SendPort coordinator;
  final SendPort reply;
  final String op;
  final int index;
  final int millis;
  final int inFlight;

  /// For `lease`: the limit per minute.
  final int limit;
}

Future<void> client(ClientJob job) async {
  final channel = RemoteCoordinatorChannel(job.coordinator);
  final buckets = List<int>.filled(bucketCount, 0);
  var count = 0;
  var allowed = 0;
  var errors = 0;
  final noLease = ProcessRateLimitStore(
    channel,
    timeout: const Duration(seconds: 5),
    leaseThreshold: 1 << 40,
  );
  final leased = ProcessRateLimitStore(
    channel,
    timeout: const Duration(seconds: 5),
  );
  final cache = ProcessStore(channel, timeout: const Duration(seconds: 5));
  final broadcaster = Broadcaster(channel);
  final owner = 'client-${job.index}';
  Future<void> once(int lane) async {
    switch (job.op) {
      case 'rate':
        await noLease.attempt('ceiling', 1 << 30, const Duration(hours: 1));
      case 'lock':
        final name = 'ceiling-lock-${job.index}-$lane';
        await cache.acquireLock(name, owner, const Duration(seconds: 10));
        await cache.releaseLock(name, owner);
      case 'cache':
        await cache.get('ceiling-key');
      case 'publish':
        await broadcaster.publish('ceiling', 'x');
      case 'lease':
        final result = await leased.attempt(
          'lease-${job.limit}',
          job.limit,
          const Duration(minutes: 1),
        );
        if (result.allowed && !result.degraded) {
          allowed++;
        }
    }
  }

  final watch = Stopwatch()..start();
  Future<void> lane(int i) async {
    while (watch.elapsedMilliseconds < job.millis) {
      final start = watch.elapsedMicroseconds;
      try {
        await once(i);
        count++;
        buckets[bucketOf(watch.elapsedMicroseconds - start)]++;
      } on Object {
        errors++;
      }
    }
  }

  await Future.wait([for (var i = 0; i < job.inFlight; i++) lane(i)]);
  job.reply.send([job.index, count, allowed, errors, buckets]);
}

/// Totals of the clients of one run.
final class RunResult {
  RunResult(
    this.ops,
    this.allowed,
    this.errors,
    this.buckets,
    this.seconds,
    this.messages,
  );

  final int ops;
  final int allowed;
  final int errors;
  final List<int> buckets;
  final double seconds;
  final int messages;

  double percentile(double q) {
    final total = buckets.fold<int>(0, (a, b) => a + b);
    if (total == 0) {
      return 0;
    }
    var seen = 0;
    for (var i = 0; i < buckets.length; i++) {
      seen += buckets[i];
      if (seen >= q * total) {
        return bucketMicros(i);
      }
    }
    return bucketMicros(buckets.length - 1);
  }

  Map<String, Object?> toJson() => {
    'ops_per_s': (ops / seconds).round(),
    'messages_per_s': (messages / seconds).round(),
    'p50_us': percentile(0.5).round(),
    'p99_us': percentile(0.99).round(),
    'errors': errors,
  };
}

/// Runs [jobs] client isolates against [coordinator] and adds them up.
Future<RunResult> run(
  Coordinator coordinator,
  SendPort port,
  List<ClientJob Function(SendPort reply)> jobs,
) async {
  final replies = ReceivePort();
  final before = coordinator.stats()['messages']! as int;
  final watch = Stopwatch()..start();
  for (final job in jobs) {
    await Isolate.spawn(client, job(replies.sendPort));
  }
  var ops = 0;
  var allowed = 0;
  var errors = 0;
  final buckets = List<int>.filled(bucketCount, 0);
  var left = jobs.length;
  await for (final message in replies) {
    final [_, count, ok, failed, hist] = message as List<Object?>;
    ops += count! as int;
    allowed += ok! as int;
    errors += failed! as int;
    final h = hist! as List<int>;
    for (var i = 0; i < bucketCount; i++) {
      buckets[i] += h[i];
    }
    if (--left == 0) {
      break;
    }
  }
  replies.close();
  final seconds = watch.elapsedMicroseconds / 1e6;
  final messages = (coordinator.stats()['messages']! as int) - before;
  return RunResult(ops, allowed, errors, buckets, seconds, messages);
}

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    for (final a in args) {
      if (a.startsWith('--$name=')) {
        return a.substring(name.length + 3);
      }
    }
    return fallback;
  }

  final millis = (double.parse(option('duration', '5')) * 1000).round();
  final clients = [
    for (final c in option('clients', '1,4,8,16').split(',')) int.parse(c),
  ];
  final inFlight = int.parse(option('in-flight', '16'));
  final json = args.contains('--json');
  final out = <String, Object?>{
    'dart': Platform.version.split(' ').first,
    'aot': const bool.fromEnvironment('dart.vm.product'),
    'processors': Platform.numberOfProcessors,
    'duration_s': millis / 1000,
    'in_flight_per_client': inFlight,
  };

  Future<RunResult> fresh(
    List<ClientJob Function(SendPort coordinator, SendPort reply)> jobs,
  ) async {
    final coordinator = createStandardCoordinator();
    final port = coordinator.listen();
    // Through the store, which encodes values as its readers expect.
    await ProcessStore(
      LocalCoordinatorChannel(coordinator),
    ).put('ceiling-key', 'value');
    try {
      return await run(coordinator, port, [
        for (final j in jobs) (reply) => j(port, reply),
      ]);
    } finally {
      coordinator.close();
    }
  }

  // 1. Ceiling per operation and client count.
  final ceiling = <String, Object?>{};
  for (final op in ['rate', 'lock', 'cache', 'publish']) {
    final byClients = <String, Object?>{};
    for (final n in clients) {
      final r = await fresh([
        for (var i = 0; i < n; i++)
          (c, reply) => ClientJob(
            coordinator: c,
            reply: reply,
            op: op,
            index: i,
            millis: millis,
            inFlight: inFlight,
          ),
      ]);
      byClients['$n'] = r.toJson();
      if (!json) {
        stdout.writeln('ceiling $op x$n: ${jsonEncode(r.toJson())}');
      }
    }
    ceiling[op] = byClients;
  }
  out['ceiling'] = ceiling;

  // 3. A rate limit probe, alone and under a publish flood.
  final flood = clients.where((n) => n > 1).fold<int>(4, max);
  ClientJob probe(SendPort c, SendPort reply) => ClientJob(
    coordinator: c,
    reply: reply,
    op: 'rate',
    index: 0,
    millis: millis,
    inFlight: 1,
  );
  final alone = await fresh([probe]);
  final coordinator = createStandardCoordinator();
  final port = coordinator.listen();
  final probeReplies = ReceivePort();
  final floodReplies = ReceivePort();
  final before = coordinator.stats()['messages']! as int;
  final watch = Stopwatch()..start();
  await Isolate.spawn(client, probe(port, probeReplies.sendPort));
  for (var i = 0; i < flood; i++) {
    await Isolate.spawn(
      client,
      ClientJob(
        coordinator: port,
        reply: floodReplies.sendPort,
        op: 'publish',
        index: i + 1,
        millis: millis,
        inFlight: 64,
      ),
    );
  }
  final probed = await probeReplies.first as List<Object?>;
  var published = 0;
  var left = flood;
  await for (final m in floodReplies) {
    published += (m as List<Object?>)[1]! as int;
    if (--left == 0) {
      break;
    }
  }
  final seconds = watch.elapsedMicroseconds / 1e6;
  final messages = (coordinator.stats()['messages']! as int) - before;
  coordinator.close();
  probeReplies.close();
  floodReplies.close();
  final underFlood = RunResult(
    probed[1]! as int,
    0,
    probed[3]! as int,
    probed[4]! as List<int>,
    seconds,
    messages,
  );
  out['saturation'] = {
    'flood_isolates': flood,
    'publish_per_s': (published / seconds).round(),
    'messages_per_s': (messages / seconds).round(),
    'rate_alone': {
      'p50_us': alone.percentile(0.5).round(),
      'p99_us': alone.percentile(0.99).round(),
    },
    'rate_under_flood': {
      'p50_us': underFlood.percentile(0.5).round(),
      'p99_us': underFlood.percentile(0.99).round(),
      'errors': underFlood.errors,
    },
  };
  if (!json) {
    stdout.writeln('saturation: ${jsonEncode(out['saturation'])}');
  }

  // 4. Leases: how many get past the limit, messages per decision.
  final lease = <String, Object?>{};
  for (final limit in [60, 1000, 10000]) {
    for (final n in [4, 16]) {
      final r = await fresh([
        for (var i = 0; i < n; i++)
          (c, reply) => ClientJob(
            coordinator: c,
            reply: reply,
            op: 'lease',
            index: i,
            millis: min(millis, 2000),
            inFlight: 4,
            limit: limit,
          ),
      ]);
      lease['$limit/min x$n'] = {
        'attempts': r.ops,
        'allowed': r.allowed,
        'over_limit': max(0, r.allowed - limit),
        'messages_per_decision': r.ops == 0
            ? 0
            : double.parse((r.messages / r.ops).toStringAsFixed(4)),
      };
      if (!json) {
        stdout.writeln(
          'lease $limit/min x$n: ${jsonEncode(lease['$limit/min x$n'])}',
        );
      }
    }
  }
  out['lease'] = lease;
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
  }
}
