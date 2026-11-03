import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Trims surrounding whitespace from every string input, except the keys
/// listed in [except] (Laravel's `TrimStrings`, which skips passwords).
final class TrimStringsMiddleware implements Middleware {
  /// Trims every string in the input, except the given keys (passwords by
  /// default).
  const TrimStringsMiddleware({
    this.except = const <String>{'password', 'password_confirmation'},
  });

  /// Keys left as sent.
  final Set<String> except;

  @override
  Future<Response> handle(Request request, Next next) {
    request.addInputTransformer((key, value) {
      if (value is String && !except.contains(key)) {
        return value.trim();
      }
      return value;
    });
    return next(request);
  }
}

/// Converts empty string inputs to `null` (Laravel's
/// `ConvertEmptyStringsToNull`).
final class ConvertEmptyStringsToNullMiddleware implements Middleware {
  /// Turns empty strings in the input into null.
  const ConvertEmptyStringsToNullMiddleware();

  @override
  Future<Response> handle(Request request, Next next) {
    request.addInputTransformer(
      (key, value) => value is String && value.isEmpty ? null : value,
    );
    return next(request);
  }
}
