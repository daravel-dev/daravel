import 'dart:async';

import '../foundation/clock.dart';

import '../http/http_exceptions.dart';
import '../http/middleware.dart';
import '../http/realtime.dart';
import '../http/request.dart';
import '../http/response.dart';
import 'radix_tree.dart';
import 'resource_controller.dart';
import 'route_entry.dart';
import 'url_signer.dart';

/// Resolves a route parameter value into a bound object (`null` → 404 when
/// [Router.bind] was registered with `orFail`).
typedef RouteBinder = FutureOr<Object?> Function(String value, Request request);

final class _GroupAttributes {
  const _GroupAttributes({
    this.prefix = '',
    this.namePrefix = '',
    this.middleware = const <Object>[],
    this.wheres = const <String, RegExp>{},
  });

  final String prefix;
  final String namePrefix;
  final List<Object> middleware;
  final Map<String, RegExp> wheres;
}

final class _Binder {
  const _Binder(this.resolve, {required this.orFail});
  final RouteBinder resolve;
  final bool orFail;
}

/// Fluent router (BLUEPRINT_V2 §7.3.2). Routes are registered during boot and
/// compiled once into per-method [RadixTree]s.
final class Router {
  final List<RouteEntry> _routes = <RouteEntry>[];
  final Map<String, RadixTree<RouteEntry>> _trees =
      <String, RadixTree<RouteEntry>>{};
  final List<_GroupAttributes> _groups = <_GroupAttributes>[];
  final Map<String, RegExp> _patterns = <String, RegExp>{};
  final Map<String, _Binder> _binders = <String, _Binder>{};
  RouteEntry? _fallback;
  bool _compiled = false;

  /// Base URL used for absolute URLs (set from `APP_URL` at boot).
  String baseUrl = 'http://localhost';

  /// Signer used by [signedUrl] (set from `APP_KEY` at boot).
  UrlSigner? signer;

  static const List<String> _allMethods = <String>[
    'GET',
    'HEAD',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'OPTIONS',
  ];

  /// Whether [compile] has run.
  bool get isCompiled => _compiled;

  /// All registered routes in registration order.
  List<RouteEntry> get routes => List.unmodifiable(_routes);

  /// The fallback route, if any.
  RouteEntry? get fallbackRoute => _fallback;

  /// Router-wide parameter patterns (`Route::pattern`).
  Map<String, RegExp> get patterns => Map.unmodifiable(_patterns);

  RouteEntry get(String path, Handler handler) =>
      match(const <String>['GET', 'HEAD'], path, handler);

  /// A WebSocket endpoint: the route's middleware (`auth`, `throttle`, ...)
  /// runs first, then the connection is upgraded and [handler] gets the
  /// socket and the request (route parameters, `Auth.user()`) in the
  /// request's scope. A plain request gets `426 Upgrade Required`.
  RouteEntry ws(String path, WebSocketHandler handler) =>
      match(const <String>['GET'], path, (request) {
        if (!isWebSocketUpgrade(request)) {
          return Response.json(
            const <String, Object?>{'message': 'Upgrade Required'},
            status: 426,
            headers: const <String, String>{'upgrade': 'websocket'},
          );
        }
        return Response.webSocket(handler);
      })..markWebSocket();

  RouteEntry post(String path, Handler handler) =>
      match(const <String>['POST'], path, handler);

  RouteEntry put(String path, Handler handler) =>
      match(const <String>['PUT'], path, handler);

  RouteEntry patch(String path, Handler handler) =>
      match(const <String>['PATCH'], path, handler);

  RouteEntry delete(String path, Handler handler) =>
      match(const <String>['DELETE'], path, handler);

  RouteEntry options(String path, Handler handler) =>
      match(const <String>['OPTIONS'], path, handler);

  /// Registers [handler] for every standard method.
  RouteEntry any(String path, Handler handler) =>
      match(_allMethods, path, handler);

  /// Registers [handler] for the given [methods].
  RouteEntry match(List<String> methods, String path, Handler handler) {
    _ensureNotCompiled();
    final attributes = _current;
    final entry = RouteEntry(
      methods: methods
          .map((method) => method.toUpperCase())
          .toList(growable: false),
      path: joinPaths(attributes.prefix, path),
      handler: handler,
      middleware: attributes.middleware,
      namePrefix: attributes.namePrefix,
      wheres: attributes.wheres,
    );
    _routes.add(entry);
    return entry;
  }

  /// Redirects [from] to [to] (`302` by default).
  RouteEntry redirect(String from, String to, {int status = 302}) =>
      any(from, (_) => Response.redirect(to, status: status));

  /// Permanent (`301`) redirect.
  RouteEntry permanentRedirect(String from, String to) =>
      redirect(from, to, status: 301);

  /// Registers the route used when nothing else matches a `GET` request.
  RouteEntry fallback(Handler handler) {
    _ensureNotCompiled();
    final entry = RouteEntry(
      methods: const <String>['GET', 'HEAD'],
      path: '/{fallbackPlaceholder*}',
      handler: handler,
      middleware: _current.middleware,
      namePrefix: _current.namePrefix,
    )..markFallback();
    _fallback = entry;
    return entry;
  }

  /// Registers routes with stacked [prefix], [name] prefix, [middleware] and
  /// parameter constraints ([where]).
  void group(
    void Function(Router router) routes, {
    String prefix = '',
    String name = '',
    List<Object> middleware = const <Object>[],
    Map<String, Object> where = const <String, Object>{},
  }) {
    _ensureNotCompiled();
    final parent = _current;
    _groups.add(
      _GroupAttributes(
        prefix: joinPaths(parent.prefix, prefix),
        namePrefix: '${parent.namePrefix}$name',
        middleware: <Object>[...parent.middleware, ...middleware],
        wheres: <String, RegExp>{
          ...parent.wheres,
          for (final entry in where.entries) entry.key: _toRegExp(entry.value),
        },
      ),
    );
    try {
      routes(this);
    } finally {
      _groups.removeLast();
    }
  }

  /// Router-wide constraint for every parameter named [param].
  void pattern(String param, Object regex) =>
      _patterns[param] = _toRegExp(regex);

  /// Registers `index`, `store`, `show`, `update` (PUT+PATCH) and `destroy`
  /// for [name] (`posts` → `/posts`, `/posts/{post}`), named `posts.index`
  /// etc. Nested names (`posts.comments`) produce nested paths.
  void apiResource(
    String name,
    ResourceController controller, {
    List<String>? only,
    List<String>? except,
    Map<String, String> parameters = const <String, String>{},
    List<Object> middleware = const <Object>[],
  }) => _resource(
    name,
    controller,
    actions: const <String>['index', 'store', 'show', 'update', 'destroy'],
    only: only,
    except: except,
    parameters: parameters,
    middleware: middleware,
  );

  /// Like [apiResource] plus `create` and `edit` for HTML forms.
  void resource(
    String name,
    WebResourceController controller, {
    List<String>? only,
    List<String>? except,
    Map<String, String> parameters = const <String, String>{},
    List<Object> middleware = const <Object>[],
  }) => _resource(
    name,
    controller,
    actions: const <String>[
      'index',
      'create',
      'store',
      'show',
      'edit',
      'update',
      'destroy',
    ],
    only: only,
    except: except,
    parameters: parameters,
    middleware: middleware,
  );

  void _resource(
    String name,
    ResourceController controller, {
    required List<String> actions,
    required List<String>? only,
    required List<String>? except,
    required Map<String, String> parameters,
    required List<Object> middleware,
  }) {
    final segments = name.split('.');
    final last = segments.last;
    final buffer = StringBuffer();
    for (final segment in segments.take(segments.length - 1)) {
      buffer.write(
        '/$segment/{${parameters[segment] ?? singularize(segment)}}',
      );
    }
    final base = '$buffer/$last';
    final param = parameters[last] ?? singularize(last);
    final item = '$base/{$param}';
    final selected = actions.where((action) {
      if (only != null && !only.contains(action)) {
        return false;
      }
      if (except != null && except.contains(action)) {
        return false;
      }
      return true;
    });
    for (final action in selected) {
      final entry = switch (action) {
        'index' => get(base, controller.index),
        'create' => get(
          '$base/create',
          (controller as WebResourceController).create,
        ),
        'store' => post(base, controller.store),
        'show' => get(item, controller.show),
        'edit' => get('$item/edit', (controller as WebResourceController).edit),
        'update' => match(
          const <String>['PUT', 'PATCH'],
          item,
          controller.update,
        ),
        'destroy' => delete(item, controller.destroy),
        _ => throw ArgumentError.value(
          action,
          'action',
          'Unknown resource action',
        ),
      };
      entry.name('$name.$action');
      if (middleware.isNotEmpty) {
        entry.middleware(middleware);
      }
    }
  }

  /// Resolves every route parameter named [param] through [resolver] before
  /// the handler runs; the result is available via `request.binding<T>()`.
  /// With [orFail], a `null` result renders a 404.
  void bind(String param, RouteBinder resolver, {bool orFail = true}) =>
      _binders[param] = _Binder(resolver, orFail: orFail);

  /// Runs the registered binders for the matched route of [request].
  /// Whether any route model binding is registered.
  bool get hasBindings => _binders.isNotEmpty;

  Future<void> resolveBindings(Request request) async {
    if (_binders.isEmpty) {
      return;
    }
    for (final entry in request.routeParams.entries) {
      final binder = _binders[entry.key];
      if (binder == null) {
        continue;
      }
      final bound = await binder.resolve(entry.value, request);
      if (bound == null && binder.orFail) {
        throw NotFoundHttpException(
          'No resource found for route parameter [${entry.key}] = "${entry.value}".',
        );
      }
      request.setBinding(entry.key, bound);
    }
  }

  /// Builds the lookup trees and resolves middleware aliases. Validates that
  /// route names are unique. Optional parameters are expanded into one tree
  /// entry per prefix (`/posts/{id?}` → `/posts` and `/posts/{id}`).
  void compile(MiddlewareRegistry registry) {
    _trees.clear();
    final names = <String>{};
    final all = <RouteEntry>[..._routes, ?_fallback];
    for (final route in all) {
      route.resolveMiddleware(registry);
      final name = route.routeName;
      if (name != null && !names.add(name)) {
        throw StateError('Duplicate route name [$name].');
      }
      if (route.isFallback) {
        continue;
      }
      for (final method in route.methods) {
        final tree = _trees.putIfAbsent(method, RadixTree<RouteEntry>.new);
        for (final variant in expandOptional(route.path)) {
          tree.insert(variant, route);
        }
      }
    }
    _compiled = true;
  }

  /// Looks up the route for [method] + [path], honouring constraints.
  /// `HEAD` falls back to `GET`. The fallback route (if any) answers `GET`
  /// requests that match nothing else.
  RouteMatch<RouteEntry>? lookup(String method, String path) {
    _ensureCompiled();
    final upper = method.toUpperCase();
    final direct = _lookupIn(upper, path);
    if (direct != null) {
      return direct;
    }
    if (upper == 'HEAD') {
      final viaGet = _lookupIn('GET', path);
      if (viaGet != null) {
        return viaGet;
      }
    }
    final fallback = _fallback;
    if (fallback != null && (upper == 'GET' || upper == 'HEAD')) {
      return RouteMatch<RouteEntry>(fallback, const <String, String>{});
    }
    return null;
  }

  RouteMatch<RouteEntry>? _lookupIn(String method, String path) =>
      _trees[method]?.lookup(
        path,
        accept: (route, params) => route.matchesConstraints(params, _patterns),
      );

  /// Methods that have a route for [path] (used for `405` / `OPTIONS`).
  List<String> allowedMethods(String path) {
    _ensureCompiled();
    final allowed = <String>{};
    for (final method in _trees.keys) {
      if (_lookupIn(method, path) != null) {
        allowed.add(method);
      }
    }
    if (allowed.contains('GET')) {
      allowed.add('HEAD');
    }
    return <String>[
      for (final method in _allMethods)
        if (allowed.contains(method)) method,
      for (final method in allowed)
        if (!_allMethods.contains(method)) method,
    ];
  }

  /// Whether a route named [name] exists.
  bool has(String name) =>
      _routes.any((route) => route.routeName == name) ||
      _fallback?.routeName == name;

  /// Generates a path for the named route, substituting [params] and
  /// appending [query]. Optional parameters may be omitted; with [absolute]
  /// the [baseUrl] is prepended.
  String url(
    String name, {
    Map<String, Object?> params = const <String, Object?>{},
    Map<String, Object?> query = const <String, Object?>{},
    bool absolute = false,
  }) {
    final route = _routes.firstWhere(
      (route) => route.routeName == name,
      orElse: () => throw ArgumentError('Route [$name] is not defined.'),
    );
    final segments = <String>[];
    for (final segment in RadixTree.splitPath(route.path)) {
      final paramName =
          RadixTree.paramName(segment) ?? RadixTree.wildcardName(segment);
      if (paramName == null) {
        segments.add(segment);
        continue;
      }
      final value = params[paramName] ?? route.defaultValues[paramName];
      if (value == null) {
        if (RadixTree.isOptional(segment)) {
          continue;
        }
        throw ArgumentError(
          'Missing required parameter [$paramName] for route [$name].',
        );
      }
      final isWildcard = RadixTree.wildcardName(segment) != null;
      segments.add(
        isWildcard
            ? '$value'.split('/').map(Uri.encodeComponent).join('/')
            : Uri.encodeComponent('$value'),
      );
    }
    var path = '/${segments.join('/')}';
    final queryString = Uri(
      queryParameters: <String, String>{
        for (final entry in query.entries)
          if (entry.value != null) entry.key: '${entry.value}',
      },
    ).query;
    if (queryString.isNotEmpty) {
      path = '$path?$queryString';
    }
    return absolute ? '${_trimmedBase()}$path' : path;
  }

  /// Generates a signed URL (absolute by default) that
  /// `ValidateSignatureMiddleware` can verify; [expires] adds expiry.
  String signedUrl(
    String name, {
    Map<String, Object?> params = const <String, Object?>{},
    Map<String, Object?> query = const <String, Object?>{},
    Duration? expires,
    bool absolute = true,
  }) {
    final signer = this.signer;
    if (signer == null) {
      throw StateError(
        'Signed URLs require APP_KEY (run `dartisan key:generate`).',
      );
    }
    final relative = url(name, params: params, query: query);
    final signed = signer.sign(
      relative,
      expires: expires == null ? null : Clock.now().add(expires),
    );
    return absolute ? '${_trimmedBase()}$signed' : signed;
  }

  /// Whether [request] carries a valid signature produced by [signedUrl].
  bool hasValidSignature(Request request) =>
      signer?.verify(request.uri) ?? false;

  /// Expands trailing optional parameters into every path variant.
  static List<String> expandOptional(String path) {
    final segments = RadixTree.splitPath(path);
    var optionalCount = 0;
    for (var i = segments.length - 1; i >= 0; i--) {
      if (RadixTree.isOptional(segments[i])) {
        optionalCount++;
      } else {
        break;
      }
    }
    for (var i = 0; i < segments.length - optionalCount; i++) {
      if (RadixTree.isOptional(segments[i])) {
        throw ArgumentError(
          'Optional parameters must be trailing in route "$path".',
        );
      }
    }
    final stripped = segments
        .map((s) => RadixTree.isOptional(s) ? '{${RadixTree.paramName(s)}}' : s)
        .toList();
    return <String>[
      for (var drop = 0; drop <= optionalCount; drop++)
        '/${stripped.take(stripped.length - drop).join('/')}',
    ];
  }

  /// Joins two path fragments into a normalized path (`/` for root).
  static String joinPaths(String base, String path) {
    final segments = <String>[
      ...RadixTree.splitPath(base),
      ...RadixTree.splitPath(path),
    ];
    return '/${segments.join('/')}';
  }

  String _trimmedBase() => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  static RegExp _toRegExp(Object pattern) =>
      pattern is RegExp ? pattern : RegExp('^(?:$pattern)\$');

  _GroupAttributes get _current =>
      _groups.isEmpty ? const _GroupAttributes() : _groups.last;

  void _ensureNotCompiled() {
    if (_compiled) {
      throw StateError(
        'Routes cannot be registered after the router has been compiled.',
      );
    }
  }

  void _ensureCompiled() {
    if (!_compiled) {
      throw StateError('Router.compile() must run before matching routes.');
    }
  }
}
