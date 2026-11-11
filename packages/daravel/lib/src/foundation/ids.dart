/// Typed ids (ADR-032, opt-in): extension types over a model's primary key,
/// so that passing a `PostId` where a `UserId` is expected does not
/// compile. They cost nothing at runtime: an extension type is erased to
/// its representation (`UserId` is an `int` once compiled), which also
/// means JSON, SQL bindings and Laravel-shared tables see the plain value.
///
/// `dartisan model:sync --typed-ids` writes one per model:
///
/// ```dart
/// extension type const UserId(int value) implements int {
///   static UserId parse(String raw) => UserId(int.parse(raw));
/// }
/// ```
library;

/// A primary key tagged with its model type [T], for code that is generic
/// over models (`TypedId<User>`). Per-model ids such as `UserId` are
/// usually nicer to read; both are erased to [value] at runtime.
extension type const TypedId<T>(Object value) implements Object {
  /// The id as an `int`; throws a [StateError] when it is not one.
  int get asInt => switch (value) {
    final int id => id,
    _ => throw StateError('Id [$value] is not an int.'),
  };

  /// The id as text (`'42'`, a UUID or a ULID).
  String get asString => '$value';
}

/// How to make an id of type [I] from a route parameter and from a value
/// read from the database. Give one to `ModelDefinition(idType: ...)` so
/// route model binding answers 404 for a parameter [parse] rejects.
final class IdType<I extends Object> {
  /// An id type from its two parsers.
  const IdType({required this.parse, required this.fromRow});

  /// An id stored as an integer, [wrap]ped into [I] (`UserId.new`).
  static IdType<I> integer<I extends Object>(I Function(int value) wrap) =>
      IdType<I>(
        parse: (raw) => wrap(int.parse(raw.trim())),
        fromRow: (value) => wrap(switch (value) {
          final int id => id,
          final num id when id == id.truncate() => id.toInt(),
          final String id => int.parse(id),
          _ => throw FormatException('Not an integer id: $value'),
        }),
      );

  /// An id stored as text (UUID, ULID, slug), [wrap]ped into [I].
  static IdType<I> string<I extends Object>(I Function(String value) wrap) =>
      IdType<I>(
        parse: (raw) {
          if (raw.isEmpty) {
            throw const FormatException('An id cannot be empty.');
          }
          return wrap(raw);
        },
        fromRow: (value) => switch (value) {
          final String id => wrap(id),
          null => throw const FormatException('Not a string id: null'),
          _ => wrap('$value'),
        },
      );

  /// Parses a route parameter (or other text); throws a [FormatException]
  /// when [raw] is not a valid id.
  final I Function(String raw) parse;

  /// Converts a primary key value as the database driver returned it.
  final I Function(Object? value) fromRow;
}

/// Parsers for route parameters, by parameter name, read by
/// `request.param<T>(name)` (`bootstrap/ids.dart`, registered with
/// `ApplicationBuilder.withIds`):
///
/// ```dart
/// void registerIds(IdParsers ids) {
///   ids.register<UserId>('user', UserId.parse);
/// }
/// ```
///
/// The registry is keyed by name, not by type, on purpose: extension types
/// are erased, so at runtime `UserId` and `PostId` are both `int` and
/// `request.param<UserId>` cannot tell which parser it was asked for. A
/// parameter name is a value the registry can look up (no reflection,
/// ADR-002), as Laravel's `Route::pattern` and `Route::bind` are.
final class IdParsers {
  final Map<String, Object Function(String raw)> _parsers =
      <String, Object Function(String raw)>{};

  /// Parses route parameter [param] with [parse]. A [FormatException] or an
  /// [ArgumentError] from [parse] makes `request.param` answer 404.
  void register<I extends Object>(String param, I Function(String raw) parse) =>
      _parsers[param] = parse;

  /// The parser of [param], if one is registered.
  Object Function(String raw)? parserFor(String param) => _parsers[param];

  /// The registered parameter names.
  Iterable<String> get params => _parsers.keys;

  /// Whether no parser is registered.
  bool get isEmpty => _parsers.isEmpty;
}
