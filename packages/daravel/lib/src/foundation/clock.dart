import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The framework's source of "now" (BLUEPRINT_V2 §7.11).
///
/// Domain time — model timestamps, token and JWT expiry, cache TTLs, rate
/// limit windows, delayed jobs, schedules, signed URLs — reads [Clock.now],
/// so tests can freeze or travel through time (Laravel `travel()` /
/// `Carbon::setTestNow()`). Wall-clock concerns (timeouts, polling
/// deadlines, log timestamps) keep using `DateTime.now()`.
abstract final class Clock {
  static DateTime? _frozen;

  /// The current time (frozen when faked).
  static DateTime now() => _frozen ?? DateTime.now();

  /// The current time in UTC.
  static DateTime nowUtc() => now().toUtc();

  /// Laravel's `now('Asia/Makassar')`: the current time in the IANA
  /// [zone], frozen with [now] in tests. Its `hour` and friends read the
  /// wall clock there; it compares and serializes as the same instant.
  static DateTime nowIn(String zone) =>
      tz.TZDateTime.from(now(), timeZone(zone));

  /// The IANA [zone]; an [ArgumentError] for an unknown name.
  static tz.Location timeZone(String zone) {
    if (!_zonesLoaded) {
      tzdata.initializeTimeZones();
      _zonesLoaded = true;
    }
    try {
      return tz.getLocation(zone);
    } on tz.LocationNotFoundException {
      throw ArgumentError.value(zone, 'zone', 'Unknown time zone');
    }
  }

  static bool _zonesLoaded = false;

  /// Whether time is currently faked.
  static bool get isFaked => _frozen != null;

  /// Freezes time at [time] (default: now).
  static DateTime fake([DateTime? time]) => _frozen = time ?? DateTime.now();

  /// Freezes time at the current instant (`$this->freezeTime()`).
  static DateTime freeze() => fake(now());

  /// Moves (frozen) time forward by [duration]; negative values go back.
  static DateTime travel(Duration duration) => _frozen = now().add(duration);

  /// Jumps to [time] and freezes there (`$this->travelTo()`).
  static DateTime travelTo(DateTime time) => _frozen = time;

  /// Returns to real time (`$this->travelBack()`).
  static void restore() => _frozen = null;

  /// Runs [body] with time frozen at [time], restoring afterwards.
  static Future<T> at<T>(DateTime time, Future<T> Function() body) async {
    final previous = _frozen;
    _frozen = time;
    try {
      return await body();
    } finally {
      _frozen = previous;
    }
  }
}

/// A date read from a driver that returns [DateTime]s, with the [text] PDO
/// would have returned. An uncast column reaches Laravel's JSON as that
/// text (`2024-01-01 10:00:00`), not as an ISO-8601 date.
final class DatabaseDateTime extends DateTime {
  DatabaseDateTime(DateTime value, this.text)
    : super.utc(
        value.year,
        value.month,
        value.day,
        value.hour,
        value.minute,
        value.second,
        value.millisecond,
        value.microsecond,
      );

  final String text;

  /// This date without its text, for a cast or timestamp attribute.
  DateTime get plain =>
      DateTime.fromMicrosecondsSinceEpoch(microsecondsSinceEpoch, isUtc: true);
}

/// Serializes [time] the way Laravel serializes dates to JSON
/// (`Carbon::toJSON()`): UTC ISO-8601 with microseconds,
/// `2026-01-02T03:04:05.000000Z`; a [DatabaseDateTime] as its text.
String jsonDate(DateTime time) {
  if (time is DatabaseDateTime) {
    return time.text;
  }
  final utc = time.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  final year = utc.year.toString().padLeft(4, '0');
  final micros = (utc.millisecond * 1000 + utc.microsecond).toString().padLeft(
    6,
    '0',
  );
  return '$year-${two(utc.month)}-${two(utc.day)}T${two(utc.hour)}:'
      '${two(utc.minute)}:${two(utc.second)}.${micros}Z';
}
