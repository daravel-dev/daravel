import '../validation/schema.dart';
import 'route_entry.dart';

/// Builds an OpenAPI 3.1 document from the compiled route table
/// (`dartisan openapi:generate`, the live `/docs/api` page).
///
/// Paths, methods, operation ids (route names), path parameters with their
/// constraints, tags and summaries come from the routes. Input schemas come
/// from `.validates(FormRequest)` / `.rules({...})` (request bodies for
/// writes, query parameters for reads) and responses from `.returns(...)`,
/// wrapped in Laravel's resource and paginator envelopes. Middleware drives
/// the documented error responses: `auth` adds bearer security and 401,
/// `can:` adds 403, `throttle` adds 429, validation adds 422.
Map<String, Object?> buildOpenApi(
  Iterable<RouteEntry> routes, {
  String title = 'Daravel API',
  String version = '1.0.0',
  String? serverUrl,
}) {
  final paths = <String, Map<String, Object?>>{};
  final schemas = <String, Object?>{};
  var usesAuth = false;
  for (final route in routes) {
    // The framework's own pages (the live `/docs/api` reference).
    if ((route.routeName ?? '').startsWith('daravel.')) {
      continue;
    }
    final path = route.path.replaceAll('?}', '}');
    final middleware = route.middlewareEntries.whereType<String>().toList();
    final authenticated = middleware.any(
      (m) => m == 'auth' || m.startsWith('auth:'),
    );
    usesAuth = usesAuth || authenticated;
    final rules = route.documentedRules();
    final input = rules == null ? null : rulesToJsonSchema(rules);
    for (final method in route.methods) {
      if (method == 'HEAD' || method == 'OPTIONS') {
        continue;
      }
      final lower = method.toLowerCase();
      final write = const {'post', 'put', 'patch'}.contains(lower);
      final validates = write || input != null;
      final declared = route.declaredResponse;
      final status =
          declared?.status ??
          (lower == 'post' ? 201 : (lower == 'delete' ? 204 : 200));
      final queryProperties = !write && input != null
          ? (input['properties'] as Map<String, Object?>? ?? const {})
          : const <String, Object?>{};
      final queryRequired = !write && input != null
          ? ((input['required'] as List<Object?>?) ?? const [])
          : const <Object?>[];
      final operation = <String, Object?>{
        'operationId': route.routeName ?? _operationId(lower, path),
        if (route.summaryText != null) 'summary': route.summaryText,
        'tags': route.tagList.isNotEmpty ? route.tagList : [_tag(path)],
        if (route.actionName != null) 'x-daravel-action': route.actionName,
        if (route.parameterNames.isNotEmpty || queryProperties.isNotEmpty)
          'parameters': [
            for (final name in route.parameterNames)
              <String, Object?>{
                'name': name,
                'in': 'path',
                'required': !route.path.contains('{$name?}'),
                'schema': _schema(route.constraints[name]),
              },
            for (final MapEntry(key: name, value: schema)
                in queryProperties.entries)
              <String, Object?>{
                'name': name,
                'in': 'query',
                'required': queryRequired.contains(name),
                'schema': schema,
              },
          ],
        if (write)
          'requestBody': <String, Object?>{
            'required': true,
            'content': {
              // File rules (format: binary) need a multipart body.
              (input != null && _hasBinary(input)
                  ? 'multipart/form-data'
                  : 'application/json'): {
                'schema': input ?? {'type': 'object'},
              },
            },
          },
        if (authenticated)
          'security': [
            {'bearerAuth': <String>[]},
          ],
        'responses': <String, Object?>{
          '$status': {
            'description': 'Successful response',
            if (declared != null && status != 204)
              'content': {
                'application/json': {'schema': _envelope(declared, schemas)},
              },
          },
          if (authenticated)
            '401': {r'$ref': '#/components/responses/Unauthenticated'},
          if (middleware.any((m) => m.startsWith('can:')) ||
              route.formRequest != null)
            '403': {r'$ref': '#/components/responses/Forbidden'},
          if (route.parameterNames.isNotEmpty)
            '404': {r'$ref': '#/components/responses/NotFound'},
          if (validates)
            '422': {r'$ref': '#/components/responses/ValidationError'},
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
      if (schemas.isNotEmpty)
        'schemas': Map<String, Object?>.fromEntries(
          schemas.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
        ),
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
          'required': ['message', 'errors'],
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

/// The response schema of [response] in Laravel's envelope; named item
/// schemas are registered in [schemas] and referenced.
Map<String, Object?> _envelope(
  RouteResponse response,
  Map<String, Object?> schemas,
) {
  final name = response.name;
  final Map<String, Object?> item;
  if (name == null) {
    item = response.schema;
  } else {
    schemas[name] = response.schema;
    item = {r'$ref': '#/components/schemas/$name'};
  }
  const nullableString = {
    'type': ['string', 'null'],
  };
  const nullableInt = {
    'type': ['integer', 'null'],
  };
  Map<String, Object?> page(Map<String, Object?> meta) => {
    'type': 'object',
    'required': ['data', 'links', 'meta'],
    'properties': {
      'data': {'type': 'array', 'items': item},
      'links': {
        'type': 'object',
        'properties': {
          'first': nullableString,
          'last': nullableString,
          'prev': nullableString,
          'next': nullableString,
        },
      },
      'meta': {'type': 'object', 'properties': meta},
    },
  };
  return switch (response.shape) {
    ResponseShape.raw => item,
    ResponseShape.item => {
      'type': 'object',
      'required': ['data'],
      'properties': {'data': item},
    },
    ResponseShape.collection => {
      'type': 'object',
      'required': ['data'],
      'properties': {
        'data': {'type': 'array', 'items': item},
      },
    },
    // PaginatedResourceResponse: the paginator array minus data and URLs.
    ResponseShape.paginated => page({
      'current_page': {'type': 'integer'},
      'from': nullableInt,
      'last_page': {'type': 'integer'},
      'links': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'url': nullableString,
            'label': {'type': 'string'},
            'page': nullableInt,
            'active': {'type': 'boolean'},
          },
        },
      },
      'path': {'type': 'string'},
      'per_page': {'type': 'integer'},
      'to': nullableInt,
      'total': {'type': 'integer'},
    }),
    ResponseShape.simplePaginated => page({
      'current_page': {'type': 'integer'},
      'current_page_url': {'type': 'string'},
      'from': nullableInt,
      'path': {'type': 'string'},
      'per_page': {'type': 'integer'},
      'to': nullableInt,
    }),
    ResponseShape.cursorPaginated => page({
      'path': {'type': 'string'},
      'per_page': {'type': 'integer'},
      'next_cursor': nullableString,
      'prev_cursor': nullableString,
    }),
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

/// Whether [schema] has a `format: binary` property at any depth.
bool _hasBinary(Object? schema) => switch (schema) {
  Map<Object?, Object?>() =>
    schema['format'] == 'binary' || schema.values.any(_hasBinary),
  List<Object?>() => schema.any(_hasBinary),
  _ => false,
};
