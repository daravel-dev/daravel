import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Trims surrounding whitespace from every string input, except the keys
/// listed in [except] (Laravel's `TrimStrings`, which skips passwords).
///
/// Like every input transformer it applies to the input as the client sent
/// it, not to fields a later `Request.merge` adds, and [except] names
/// dotted paths (`user.password`).
final class TrimStringsMiddleware implements Middleware {
  /// Trims every string in the input, except the given keys
  /// ([defaultExcept]: the password fields, as in Laravel).
  const TrimStringsMiddleware({this.except = defaultExcept});

  /// The keys Laravel's `TrimStrings` leaves as sent: `current_password`,
  /// `password` and `password_confirmation`. Extend it with
  /// `{...TrimStringsMiddleware.defaultExcept, 'pin'}`.
  static const Set<String> defaultExcept = <String>{
    'current_password',
    'password',
    'password_confirmation',
  };

  /// Keys left as sent, as dotted paths.
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
