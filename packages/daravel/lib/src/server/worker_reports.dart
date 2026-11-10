import 'dart:convert';
import 'dart:isolate';

import 'coordinator.dart';

/// The latest report of every worker isolate, by topic: a worker
/// publishes what it measured on its own ([WorkerReports.publish]) and any
/// worker collects all
/// of them, so a page served by one worker can show the whole process.
/// Reports must be sendable (maps, lists, strings, numbers, booleans). The
/// worker sends a report JSON can hold as JSON text, which the VM shares
/// between isolates instead of deep-copying it (ADR-031); the coordinator
/// keeps that text as is and the collecting worker decodes it.
///
/// ```dart
/// final reports = WorkerReports(container.make<CoordinatorChannel>());
/// await reports.publish('pulse', recorder.report());
/// final all = await reports.collect('pulse'); // {worker: report}
/// ```
final class WorkerReportService
    with PrioritizedService
    implements CoordinatorService, WorkerAwareService {
  /// Bulk: put off while lagging, refused while saturated.
  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  /// The coordinator service name.
  static const String serviceName = 'worker_reports';

  final Map<String, Map<String, Object?>> _topics = {};

  @override
  String get name => serviceName;

  @override
  Object? handle(String op, Map<String, Object?> args) {
    final topic = args['topic']! as String;
    switch (op) {
      case 'publish':
        (_topics[topic] ??= {})[args['worker']! as String] = args['report'];
        return null;
      case 'collect':
        return Map<String, Object?>.of(_topics[topic] ?? const {});
      case 'forget':
        _topics[topic]?.remove(args['worker']! as String);
        return null;
      default:
        throw CoordinatorException('Unknown worker_reports op [$op].');
    }
  }

  @override
  void forgetWorker(String worker) {
    for (final reports in _topics.values) {
      reports.remove(worker);
    }
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{
    for (final MapEntry(:key, :value) in _topics.entries) key: value.length,
  };
}

/// A worker's side of [WorkerReportService].
final class WorkerReports {
  /// Reports of [worker] through [channel].
  WorkerReports(this.channel, {String? worker})
    : worker = worker ?? _isolateName();

  /// The channel to the coordinator.
  final CoordinatorChannel channel;

  /// This worker's name: the isolate's (`daravel-worker-N` under a
  /// supervisor, the same after a respawn).
  final String worker;

  static String _isolateName() =>
      Isolate.current.debugName ?? '${Isolate.current.hashCode}';

  /// Numbers, booleans and null as they are (no copy to save), the rest as
  /// JSON text. A plain string is encoded too, so [_decode] can tell it
  /// apart; a value JSON cannot hold travels as itself.
  static Object? _encode(Object? report) {
    switch (report) {
      case null || num() || bool():
        return report;
      default:
        try {
          return jsonEncode(report);
        } on JsonUnsupportedObjectError {
          return report;
        }
    }
  }

  static Object? _decode(Object? wire) =>
      wire is String ? jsonDecode(wire) : wire;

  /// Replaces this worker's report on [topic].
  Future<void> publish(String topic, Object? report) async {
    await channel.call(WorkerReportService.serviceName, 'publish', {
      'topic': topic,
      'worker': worker,
      'report': _encode(report),
    });
  }

  /// Every worker's latest report on [topic], by worker name.
  Future<Map<String, Object?>> collect(String topic) async {
    final result = await channel.call(
      WorkerReportService.serviceName,
      'collect',
      {'topic': topic},
    );
    return <String, Object?>{
      for (final MapEntry(:key, :value)
          in (result! as Map<String, Object?>).entries)
        key: _decode(value),
    };
  }

  /// Drops this worker's report on [topic] (on shutdown).
  Future<void> forget(String topic) async {
    await channel.call(WorkerReportService.serviceName, 'forget', {
      'topic': topic,
      'worker': worker,
    });
  }
}
