import 'dart:async';

import '../http/middleware.dart';
import '../http/request.dart';
import '../validation/form_request.dart';
import 'radix_tree.dart';

/// A route handler. May return a `Response`, a `Responsable`, a JSON-able
/// value (`Map`, `List`, `num`, `bool`, `JsonSerializable`), a `String`
/// (text) or `null` (empty 200).
typedef Handler = FutureOr<Object?> Function(Request request);

/// Well-known parameter patterns (Laravel `whereNumber`, `whereUuid`, ...).
abstract final class RoutePatterns {
  static final RegExp number = RegExp(r'^[0-9]+$');
  static final RegExp alpha = RegExp(r'^[a-zA-Z]+$');
  static final RegExp alphaNumeric = RegExp(r'^[a-zA-Z0-9]+$');
  static final RegExp uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final RegExp ulid = RegExp(
    r'^[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$',
  );
}

/// A registered route with fluent configuration (BLUEPRINT_V2 §7.3.2).
final class RouteEntry {
  RouteEntry({
    required this.methods,
    required this.path,
    required this.handler,
    List<Object> middleware = const <Object>[],
    this._namePrefix = '',
    Map<String, RegExp> wheres = const <String, RegExp>{},
  }) : _middleware = List<Object>.of(middleware),
       _wheres = Map<String, RegExp>.of(wheres);

  /// Upper-cased HTTP methods served by this route.
  final List<String> methods;

  /// Normalized path (`/api/users/{id}`), optional markers preserved.
  final String path;

  /// The handler.
  final Handler handler;

  final List<Object> _middleware;
  final String _namePrefix;
  final Map<String, RegExp> _wheres;
  final Map<String, Object?> _defaults = <String, Object?>{};
  String? _name;
  List<Middleware> _resolved = const <Middleware>[];
  Duration? _timeout;
  int? _bodyLimitBytes;
  bool _isFallback = false;
  bool _isWebSocket = false;
  String? _summary;
  List<String> _tags = const <String>[];
  FormRequest? _formRequest;
  Map<String, Object>? _rules;
  RouteResponse? _response;
  String? _action;

  /// The form request validating this route ([validates]).
  FormRequest? get formRequest => _formRequest;

  /// Inline validation rules of this route ([rules]).
  Map<String, Object>? get declaredRules => _rules;

  /// The declared response ([returns]).
  RouteResponse? get declaredResponse => _response;

  /// The controller action this route stands for ([action]), such as
  /// `PostController@store` (Laravel's route action; used by `daragic`).
  String? get actionName => _action;

  /// The rules describing this route's input: the inline [rules], or those
  /// of the [validates] form request evaluated against an empty request
  /// (for documentation; `null` when none are declared or the form
  /// request's rules need a real request).
  Map<String, Object>? documentedRules() {
    final inline = _rules;
    if (inline != null) {
      return inline;
    }
    final form = _formRequest;
    if (form == null) {
      return null;
    }
    try {
      return form.rules(Request.fake(method: methods.first, path: path));
    } on Object {
      return null;
    }
  }

  /// The route name (including any group prefix), if set.
  String? get routeName => _name;

  /// Middleware entries as registered (instances or aliases).
  List<Object> get middlewareEntries => List.unmodifiable(_middleware);

  /// Middleware resolved at compile time.
  List<Middleware> get resolvedMiddleware => _resolved;

  /// Parameter constraints (`where`).
  Map<String, RegExp> get constraints => Map.unmodifiable(_wheres);

  /// Default values for optional parameters.
  Map<String, Object?> get defaultValues => Map.unmodifiable(_defaults);

  /// Per-route handler timeout (overrides the server default).
  Duration? get timeoutDuration => _timeout;

  /// Per-route body limit in bytes (overrides `BodyLimitsMiddleware`).
  int? get bodyLimitBytes => _bodyLimitBytes;

  /// Whether this is the fallback route.
  bool get isFallback => _isFallback;

  /// Whether this is a WebSocket endpoint ([Router.ws]).
  bool get isWebSocket => _isWebSocket;

  /// Short description (OpenAPI `summary`).
  String? get summaryText => _summary;

  /// Tags (OpenAPI `tags`).
  List<String> get tagList => _tags;

  /// Parameter names in order of appearance (optional markers stripped).
  List<String> get parameterNames => <String>[
    for (final segment in RadixTree.splitPath(path))
      ?RadixTree.paramName(segment) ?? RadixTree.wildcardName(segment),
  ];

  /// Names of the optional parameters.
  List<String> get optionalParameterNames => <String>[
    for (final segment in RadixTree.splitPath(path))
      if (RadixTree.isOptional(segment)) RadixTree.paramName(segment)!,
  ];

  /// Assigns a name (prefixed by the enclosing group name prefix).
  RouteEntry name(String name) {
    _name = '$_namePrefix$name';
    return this;
  }

  /// Appends route middleware (instances, aliases or groups).
  RouteEntry middleware(List<Object> entries) {
    _middleware.addAll(entries);
    return this;
  }

  /// Removes middleware of type [T] from this route.
  RouteEntry withoutMiddleware<T extends Middleware>() {
    _middleware.removeWhere((entry) => entry is T);
    return this;
  }

  /// Constrains [param] to [pattern] (anchored automatically).
  RouteEntry where(String param, Object pattern) {
    _wheres[param] = pattern is RegExp ? pattern : RegExp('^(?:$pattern)\$');
    return this;
  }

  RouteEntry whereNumber(String param) => where(param, RoutePatterns.number);
  RouteEntry whereAlpha(String param) => where(param, RoutePatterns.alpha);
  RouteEntry whereAlphaNumeric(String param) =>
      where(param, RoutePatterns.alphaNumeric);
  RouteEntry whereUuid(String param) => where(param, RoutePatterns.uuid);
  RouteEntry whereUlid(String param) => where(param, RoutePatterns.ulid);

  /// Constrains [param] to one of [values].
  RouteEntry whereIn(String param, List<String> values) =>
      where(param, RegExp('^(?:${values.map(RegExp.escape).join('|')})\$'));

  /// Default values for optional parameters that were not supplied.
  RouteEntry defaults(Map<String, Object?> values) {
    _defaults.addAll(values);
    return this;
  }

  /// Sets a handler timeout; the kernel answers `503` when exceeded.
  RouteEntry timeout(Duration duration) {
    _timeout = duration;
    return this;
  }

  /// Sets the maximum body size accepted by this route.
  RouteEntry bodyLimit(int bytes) {
    _bodyLimitBytes = bytes;
    return this;
  }

  /// OpenAPI metadata: short summary.
  RouteEntry summary(String text) {
    _summary = text;
    return this;
  }

  /// OpenAPI metadata: tags.
  RouteEntry tags(List<String> tags) {
    _tags = List.unmodifiable(tags);
    return this;
  }

  /// Validates every request with [request] before the handler runs (after
  /// the route middleware), like a type-hinted `FormRequest` in Laravel:
  /// `authorize()` false answers 403, invalid input 422. The handler reads
  /// the result with `request.validated()`. The rules also document the
  /// route (`dartisan openapi:generate`, generated clients).
  RouteEntry validates(FormRequest request) {
    _formRequest = request;
    return this;
  }

  /// Like [validates] with inline rules (`request.validate(rules)`).
  RouteEntry rules(Map<String, Object> rules) {
    _rules = Map.unmodifiable(rules);
    return this;
  }

  /// Documents the response: [schema] is the JSON Schema of one item (for
  /// example one resource's `toArray`), [shape] says how it is returned
  /// (`{"data": item}`, a collection or one of Laravel's paginators) and
  /// [name] registers it under `components/schemas`.
  RouteEntry returns(
    Map<String, Object?> schema, {
    String? name,
    ResponseShape shape = .item,
    int? status,
  }) {
    _response = RouteResponse(schema, name: name, shape: shape, status: status);
    return this;
  }

  /// Names the controller action this route stands for
  /// (`PostController@store`), as Laravel's route action does.
  RouteEntry action(String action) {
    _action = action;
    return this;
  }

  /// Marks this route as the fallback. Called by `Router.fallback`.
  void markFallback() => _isFallback = true;

  /// Marks this route as a WebSocket endpoint. Called by `Router.ws`.
  void markWebSocket() => _isWebSocket = true;

  /// Whether every captured parameter satisfies this route's constraints
  /// (and the router-wide [globalPatterns] for unconstrained parameters).
  bool matchesConstraints(
    Map<String, String> params, [
    Map<String, RegExp> globalPatterns = const <String, RegExp>{},
  ]) {
    for (final entry in params.entries) {
      final pattern = _wheres[entry.key] ?? globalPatterns[entry.key];
      if (pattern != null && !pattern.hasMatch(entry.value)) {
        return false;
      }
    }
    return true;
  }

  /// Resolves aliases into instances. Called by `Router.compile`.
  void resolveMiddleware(MiddlewareRegistry registry) {
    _resolved = List.unmodifiable(registry.resolveAll(_middleware));
  }

  @override
  String toString() =>
      'RouteEntry(${methods.join('|')} $path'
      '${_name == null ? '' : ' name=$_name'})';
}

/// How a route returns its item schema (see [RouteEntry.returns]).
enum ResponseShape {
  /// `{"data": item}` (a `JsonResource`).
  item,

  /// The item itself, without a `data` wrapper.
  raw,

  /// `{"data": [item, ...]}` (`JsonResource.collection` of a list).
  collection,

  /// `{"data": [...], "links": {...}, "meta": {...}}` from `paginate()`.
  paginated,

  /// The same envelope from `simplePaginate()`.
  simplePaginated,

  /// The same envelope from `cursorPaginate()`.
  cursorPaginated,
}

/// A documented route response (see [RouteEntry.returns]).
final class RouteResponse {
  const RouteResponse(
    this.schema, {
    this.name,
    this.shape = ResponseShape.item,
    this.status,
  });

  /// JSON Schema of one item.
  final Map<String, Object?> schema;

  /// Component name (`components/schemas/<name>`), when set.
  final String? name;
  final ResponseShape shape;

  /// Status code; defaults to 201 for POST, 200 otherwise.
  final int? status;
}
