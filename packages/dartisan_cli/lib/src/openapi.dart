import 'package:daravel/daravel.dart';

/// Builds an OpenAPI 3.1 document from the compiled route table
/// (`dartisan openapi:generate`; BLUEPRINT_V2 §7.10.x).
///
/// Paths, methods, operation ids (route names), path parameters with their
/// constraints, tags and summaries come from the routes. Middleware drives
/// the documented error responses: `auth` adds bearer security and 401,
/// `can:` adds 403, `throttle` adds 429, write methods add 422.
Map<String, Object?> buildOpenApi(
  Iterable<RouteEntry> routes, {
  String title = 'Daravel API',
  String version = '1.0.0',
  String? serverUrl,
}) {
  final paths = <String, Map<String, Object?>>{};
  var usesAuth = false;
  for (final route in routes) {
    final path = route.path.replaceAll('?}', '}');
    final middleware = route.middlewareEntries.whereType<String>().toList();
    final authenticated = middleware.any(
      (m) => m == 'auth' || m.startsWith('auth:'),
    );
    usesAuth = usesAuth || authenticated;
    for (final method in route.methods) {
      if (method == 'HEAD' || method == 'OPTIONS') {
        continue;
      }
      final lower = method.toLowerCase();
      final write = const {'post', 'put', 'patch'}.contains(lower);
      final operation = <String, Object?>{
        'operationId': route.routeName ?? _operationId(lower, path),
        if (route.summaryText != null) 'summary': route.summaryText,
        'tags': route.tagList.isNotEmpty ? route.tagList : [_tag(path)],
        if (route.parameterNames.isNotEmpty)
          'parameters': [
            for (final name in route.parameterNames)
              <String, Object?>{
                'name': name,
                'in': 'path',
                'required': !route.path.contains('{$name?}'),
                'schema': _schema(route.constraints[name]),
              },
          ],
        if (write)
          'requestBody': <String, Object?>{
            'content': {
              'application/json': {
                'schema': {'type': 'object'},
              },
            },
          },
        if (authenticated)
          'security': [
            {'bearerAuth': <String>[]},
          ],
        'responses': <String, Object?>{
          (lower == 'post' ? '201' : (lower == 'delete' ? '204' : '200')): {
            'description': 'Successful response',
          },
          if (authenticated)
            '401': {r'$ref': '#/components/responses/Unauthenticated'},
          if (middleware.any((m) => m.startsWith('can:')))
            '403': {r'$ref': '#/components/responses/Forbidden'},
          if (route.parameterNames.isNotEmpty)
            '404': {r'$ref': '#/components/responses/NotFound'},
          if (write) '422': {r'$ref': '#/components/responses/ValidationError'},
          if (middleware.any((m) => m.startsWith('throttle')))
            '429': {r'$ref': '#/components/responses/TooManyRequests'},
        },
      };
      (paths[path] ??= <String, Object?>{})[lower] = operation;
    }
  }
  final message = {
    'type': 'object',
    'properties': {
      'message': {'type': 'string'},
    },
  };
  Map<String, Object?> response(String description, [Object? schema]) => {
    'description': description,
    'content': {
      'application/json': {'schema': schema ?? message},
    },
  };
  return <String, Object?>{
    'openapi': '3.1.0',
    'info': {'title': title, 'version': version},
    if (serverUrl != null)
      'servers': [
        {'url': serverUrl},
      ],
    'paths': Map<String, Object?>.fromEntries(
      paths.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'components': {
      if (usesAuth)
        'securitySchemes': {
          'bearerAuth': {'type': 'http', 'scheme': 'bearer'},
        },
      'responses': {
        'Unauthenticated': response('Unauthenticated.'),
        'Forbidden': response('This action is unauthorized.'),
        'NotFound': response('Not Found'),
        'TooManyRequests': response('Too Many Attempts.'),
        'ValidationError': response('The given data was invalid.', {
          'type': 'object',
          'properties': {
            'message': {'type': 'string'},
            'errors': {
              'type': 'object',
              'additionalProperties': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
        }),
      },
    },
  };
}

Map<String, Object?> _schema(RegExp? constraint) {
  if (constraint == null) {
    return {'type': 'string'};
  }
  if (constraint.pattern == RoutePatterns.number.pattern) {
    return {'type': 'integer'};
  }
  if (constraint.pattern == RoutePatterns.uuid.pattern) {
    return {'type': 'string', 'format': 'uuid'};
  }
  return {'type': 'string', 'pattern': constraint.pattern};
}

String _tag(String path) {
  final segments = path
      .split('/')
      .where((s) => s.isNotEmpty && !s.startsWith('{'))
      .toList();
  if (segments.isEmpty) {
    return 'default';
  }
  return segments.first == 'api' && segments.length > 1
      ? segments[1]
      : segments.first;
}

String _operationId(String method, String path) {
  final words = path
      .split(RegExp(r'[/{}?-]+'))
      .where((s) => s.isNotEmpty)
      .map((s) => s[0].toUpperCase() + s.substring(1));
  return words.isEmpty ? '${method}Root' : '$method${words.join()}';
}
