import 'package:daravel/daravel.dart';

/// A job that finishes at once, on the `default` queue.
final class QuickJob extends Job {
  /// Job [n] of a batch.
  const QuickJob(this.n);

  /// From its stored JSON.
  factory QuickJob.fromJson(Map<String, Object?> json) =>
      QuickJob((json['n']! as num).toInt());

  /// The job's number.
  final int n;

  /// The registry name.
  static const String name = 'quick';

  @override
  String get jobName => name;

  @override
  List<String> get tags => const ['demo:quick'];

  @override
  Map<String, Object?> toJson() => {'n': n};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// A job that takes a while, on the `reports` queue.
final class SlowJob extends Job {
  /// A job that runs for [ms] milliseconds.
  const SlowJob(this.ms);

  /// From its stored JSON.
  factory SlowJob.fromJson(Map<String, Object?> json) =>
      SlowJob((json['ms']! as num).toInt());

  /// How long it runs.
  final int ms;

  /// The registry name.
  static const String name = 'slow';

  @override
  String get jobName => name;

  @override
  Map<String, Object?> toJson() => {'ms': ms};

  @override
  Future<void> handle(JobContext ctx) =>
      Future<void>.delayed(Duration(milliseconds: ms));
}

/// A job that fails its first attempts, to show retries and the Failed tab.
final class FlakyJob extends Job {
  /// A job that fails while its attempt is below [succeedOn].
  const FlakyJob({this.succeedOn = 3});

  /// From its stored JSON.
  factory FlakyJob.fromJson(Map<String, Object?> json) =>
      FlakyJob(succeedOn: (json['succeed_on'] as num?)?.toInt() ?? 3);

  /// The attempt that succeeds; above [tries] the job fails for good.
  final int succeedOn;

  /// The registry name.
  static const String name = 'flaky';

  @override
  String get jobName => name;

  @override
  int get tries => 3;

  @override
  Map<String, Object?> toJson() => {'succeed_on': succeedOn};

  @override
  Future<void> handle(JobContext ctx) async {
    if (ctx.attempt < succeedOn) {
      throw StateError('Attempt ${ctx.attempt} failed on purpose.');
    }
  }
}

/// The job registry (`withJobs`).
final List<JobDefinition> jobs = [
  JobDefinition(QuickJob.name, QuickJob.fromJson),
  JobDefinition(SlowJob.name, SlowJob.fromJson),
  JobDefinition(FlakyJob.name, FlakyJob.fromJson),
];
