/// A value that shows itself to the logger as plain data (maps, lists,
/// text), so the logger redacts what it holds before any handler writes
/// it: `Headers` is one, and a value of an application class that carries
/// credentials can be one too.
abstract interface class Loggable {
  /// The value as the logger should see it.
  Object? toLogValue();
}
