import 'package:daravel/daravel.dart';

import 'config.dart';
import 'manager.dart';
import 'middleware.dart';
import 'session.dart';

/// Never flashed (`$dontFlash` of Laravel's exception handler); keys in dot
/// notation as `Arr::forget` reads them. `withSession(dontFlash:)` adds to
/// them.
const Set<String> defaultDontFlash = {
  'current_password',
  'password',
  'password_confirmation',
};

/// `Handler::invalid()`: a browser or an Inertia visit goes back with the
/// errors and its input flashed, without uploaded files at any depth
/// (`RedirectResponse::removeFilesFromInput`) and without the
/// [defaultDontFlash] keys. Clients expecting JSON, and requests without a
/// session, fall through to the 422.
///
/// See [Session.flashErrors] for a page Laravel renders from this session.
Future<Response?> redirectInvalidRequest(
  ValidationException error,
  Request request,
) => _redirectInvalid(error, request, defaultDontFlash);

Future<Response?> _redirectInvalid(
  ValidationException error,
  Request request,
  Set<String> dontFlash,
) async {
  final session = Session.current;
  if (session == null || request.expectsJson) {
    return null;
  }
  var input = flashableInput(await request.all());
  for (final key in dontFlash) {
    input = _forget(input, key)! as Map<String, Object?>;
  }
  session
    ..flashErrors(error.errors)
    ..flash('_old_input', input);
  return Response.back(request, previous: session.previousUrl);
}

/// [input] without uploaded files, at any depth, as Laravel's
/// `RedirectResponse::removeFilesFromInput`. A list that loses an element
/// keeps the indices of the others, as a PHP array does after `unset`: it
/// becomes a map of them (`old('photos.1')` still finds the second).
Map<String, Object?> flashableInput(Map<String, Object?> input) =>
    _withoutFiles(input)! as Map<String, Object?>;

Object? _withoutFiles(Object? value) => switch (value) {
  final Map<Object?, Object?> map => <String, Object?>{
    for (final MapEntry(:key, :value) in map.entries)
      if (value is! UploadedFile) '$key': _withoutFiles(value),
  },
  final List<Object?> list when list.any((e) => e is UploadedFile) =>
    <String, Object?>{
      for (var i = 0; i < list.length; i++)
        if (list[i] is! UploadedFile) '$i': _withoutFiles(list[i]),
    },
  final List<Object?> list => [for (final e in list) _withoutFiles(e)],
  _ => value,
};

/// [value] without [key], as `Arr::forget`: the key itself when the top
/// level has it, else its dot-notation path through maps and lists.
Object? _forget(Object? value, String key) {
  if (value is Map<String, Object?> && value.containsKey(key)) {
    return {...value}..remove(key);
  }
  return _forgetPath(value, key.split('.'));
}

Object? _forgetPath(Object? value, List<String> parts) {
  final part = parts.first;
  final rest = parts.sublist(1);
  switch (value) {
    case final Map<String, Object?> map when map.containsKey(part):
      return rest.isEmpty
          ? ({...map}..remove(part))
          : {...map, part: _forgetPath(map[part], rest)};
    case final List<Object?> list:
      final index = int.tryParse(part);
      if (index == null || index < 0 || index >= list.length) {
        return list;
      }
      if (rest.isNotEmpty) {
        return [...list]..[index] = _forgetPath(list[index], rest);
      }
      // Unset in a PHP list: the others keep their indices.
      return <String, Object?>{
        for (var i = 0; i < list.length; i++)
          if (i != index) '$i': list[i],
      };
    default:
      return value;
  }
}

/// `withSession()` on the application builder.
extension SessionApplicationBuilder on ApplicationBuilder {
  /// Adds Laravel-compatible sessions (`SESSION_*` settings):
  ///
  /// - the [SessionManager] with the `file`, `database`, `cache` and
  ///   `array` drivers (`withRedis()` from `daravel_redis` adds `redis`);
  /// - the `encrypt_cookies`, `session` and `csrf` middleware aliases, and
  ///   the `web` group that runs the three in Laravel's order;
  /// - `request.session` and `Session.current` inside those routes.
  ///
  /// Put the `web` group on the routes that need a session:
  /// `router.group((r) {...}, middleware: ['web'])`. With the `database`
  /// driver, add [CreateSessionsTable] to the migrations.
  ///
  /// [dontFlash] adds keys (dot notation) that a failed validation does not
  /// flash back, to [defaultDontFlash] (Laravel's
  /// `$exceptions->dontFlash([...])`).
  ApplicationBuilder withSession({
    List<String> csrfExcept = const <String>[],
    List<String> cookiesExcept = const <String>[],
    List<String> dontFlash = const <String>[],
  }) => withConfig<SessionConfig>(SessionConfig.fromEnv)
      .withConfigCheck(SessionConfig.check)
      .withBindings((container) {
        container.singleton<SessionManager>(
          (c) => SessionManager(
            c.make<ConfigRepository>().section<SessionConfig>(),
            basePath: c.make<Application>().basePath,
          ),
        );
        final keys = {...defaultDontFlash, ...dontFlash};
        container.make<ExceptionHandler>().render<ValidationException>(
          (error, request) => _redirectInvalid(error, request, keys),
        );
      })
      .withMiddleware(
        (middleware) => middleware
          ..alias(
            'encrypt_cookies',
            EncryptCookiesMiddleware(except: cookiesExcept),
          )
          ..alias('session', const StartSessionMiddleware())
          ..alias('csrf', VerifyCsrfTokenMiddleware(except: csrfExcept))
          ..group('web', const <Object>['encrypt_cookies', 'session', 'csrf']),
      );
}
