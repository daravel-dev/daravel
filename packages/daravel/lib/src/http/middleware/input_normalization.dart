import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Trims surrounding whitespace from every string input, except the keys
/// listed in [except] (Laravel's `TrimStrings`, which skips passwords).
final class TrimStringsMiddleware implements Middleware {
  const TrimStringsMiddleware({
    this.except = const <String>{'password', 'password_confirmation'},
  });

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
  const ConvertEmptyStringsToNullMiddleware();

  @override
  Future<Response> handle(Request request, Next next) {
    request.addInputTransformer(
      (key, value) => value is String && value.isEmpty ? null : value,
    );
    return next(request);
  }
}
