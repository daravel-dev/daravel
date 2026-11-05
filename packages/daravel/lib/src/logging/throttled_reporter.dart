/// Reports at most one error per [interval], with the number of errors
/// left unreported since the last report: a failure that repeats on every
/// request (a coordinator that times out under load) is logged once a
/// second instead of once per request, on top of the overload that caused
/// it.
final class ThrottledReporter {
  /// Calls [report] with the first error of each [interval] and how many
  /// errors were skipped before it. [elapsed] is a monotonic clock, for
  /// tests.
  ThrottledReporter(
    this.report, {
    this.interval = const Duration(seconds: 1),
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _monotonic();

  /// Receives an error and the number of errors skipped before it.
  final void Function(Object error, int skipped) report;

  /// The least time between two reports.
  final Duration interval;

  final Duration Function() _elapsed;
  Duration? _last;
  int _skipped = 0;

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// Reports [error] unless one was reported less than [interval] ago.
  void call(Object error) {
    final now = _elapsed();
    final last = _last;
    if (last != null && now - last < interval) {
      _skipped++;
      return;
    }
    _last = now;
    final skipped = _skipped;
    _skipped = 0;
    report(error, skipped);
  }
}
