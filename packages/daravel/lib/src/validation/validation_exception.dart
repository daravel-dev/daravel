import '../http/http_exceptions.dart';

/// Thrown when validation fails; rendered as a Laravel-compatible `422`:
/// `{"message": "...", "errors": {"field": ["..."]}}`.
base class ValidationException extends HttpException {
  ValidationException(Map<String, List<String>> errors)
    : errors = Map.unmodifiable({
        for (final entry in errors.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      }),
      super(422, summarize(errors));

  /// Builds an exception from literal messages (`withMessages`).
  factory ValidationException.withMessages(Map<String, Object> messages) =>
      ValidationException({
        for (final entry in messages.entries)
          entry.key: switch (entry.value) {
            final List<Object?> list => list.map((m) => '$m').toList(),
            _ => <String>['${entry.value}'],
          },
      });

  /// Errors keyed by attribute (`items.0.id`).
  final Map<String, List<String>> errors;

  /// Laravel 12 summary: the first message plus `(and N more errors)`.
  static String summarize(Map<String, List<String>> errors) {
    final all = errors.values.expand((messages) => messages).toList();
    if (all.isEmpty) {
      return 'The given data was invalid.';
    }
    final remaining = all.length - 1;
    if (remaining == 0) {
      return all.first;
    }
    return '${all.first} (and $remaining more ${remaining == 1 ? 'error' : 'errors'})';
  }

  /// JSON payload rendered by the exception handler.
  Map<String, Object?> toJson() => {'message': message, 'errors': errors};
}
