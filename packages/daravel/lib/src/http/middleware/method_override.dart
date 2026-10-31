import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// HTML forms and multipart uploads can only POST: `_method` or the
/// `X-HTTP-Method-Override` header names the real verb, as Symfony's
/// `Request::getMethod()` reads them.
///
/// Only form bodies are read, so JSON and raw uploads stay untouched. Symfony
/// takes any verb but GET, HEAD, CONNECT and TRACE; this takes the three that
/// forms need.
final class MethodOverrideMiddleware implements Middleware {
  const MethodOverrideMiddleware();

  static const Set<String> allowed = {'PUT', 'PATCH', 'DELETE'};

  @override
  Future<Response> handle(Request request, Next next) async {
    if (request.method == 'POST') {
      final target = await _target(request);
      if (allowed.contains(target)) {
        request.overrideMethod(target!);
      }
    }
    return next(request);
  }

  Future<String?> _target(Request request) async {
    final header = request.headers.first('x-http-method-override');
    if (header != null && header.isNotEmpty) {
      return header.toUpperCase();
    }
    final contentType = (request.headers.contentType ?? '').toLowerCase();
    final isForm =
        contentType.contains('application/x-www-form-urlencoded') ||
        contentType.contains('multipart/form-data');
    final body = isForm ? await request.body() : null;
    final value = body is Map ? body['_method'] : null;
    return switch (value ?? request.queryInput['_method']) {
      final String method => method.toUpperCase(),
      _ => null,
    };
  }
}
