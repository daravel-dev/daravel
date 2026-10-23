import '../database/orm/model.dart';
import '../database/query/paginator.dart';
import 'request.dart';
import 'response.dart';

/// Marker for attributes omitted by `when`/`whenLoaded` (Laravel
/// `MissingValue`).
final class MissingValue {
  const MissingValue._();
}

/// The single [MissingValue] instance.
const MissingValue missing = MissingValue._();

/// Attributes merged into the parent map (`mergeWhen`).
final class MergeValue {
  const MergeValue(this.values);

  final Map<String, Object?> values;
}

/// Shape of a resource payload: the wrapping key (`data`) is global, like
/// Laravel's `JsonResource::$wrap`.
abstract final class ResourceWrapping {
  static String? key = 'data';

  /// Disables the `data` wrapper for single resources and plain
  /// collections (paginated collections keep it, as in Laravel).
  static void disable() => key = null;

  static void wrap(String name) => key = name;
}

/// Transforms a value (usually a [Model]) into its API representation
/// (Laravel `JsonResource`; BLUEPRINT_V2 §7.10.5).
///
/// ```dart
/// final class UserResource extends JsonResource<User> {
///   UserResource(super.resource);
///   @override
///   Map<String, Object?> toArray(Request? request) => {
///     'id': resource.id,
///     'email': resource.email,
///     'posts': whenLoaded('posts', (posts) => PostResource.collection(posts)),
///   };
/// }
/// ```
abstract class JsonResource<T> implements JsonSerializable, Responsable {
  JsonResource(this.resource);

  final T resource;
  final Map<String, Object?> _additional = <String, Object?>{};
  int? _status;
  final Map<String, String> _headers = <String, String>{};

  /// Attributes of the resource. [request] is `null` when serialised
  /// outside a response (nested in a map, logged, …).
  Map<String, Object?> toArray(Request? request);

  /// Top-level data next to the wrapper (Laravel `with()`).
  Map<String, Object?> withMeta(Request? request) => const <String, Object?>{};

  /// Adds top-level data to this response (Laravel `additional()`).
  JsonResource<T> additional(Map<String, Object?> data) {
    _additional.addAll(data);
    return this;
  }

  /// Overrides the response status (`->response()->setStatusCode()`).
  JsonResource<T> withStatus(int status) {
    _status = status;
    return this;
  }

  JsonResource<T> withHeader(String name, String value) {
    _headers[name] = value;
    return this;
  }

  // ---------------------------------------------------------------------------
  // Conditional attributes
  // ---------------------------------------------------------------------------

  /// [value] when [condition], otherwise [otherwise] or omitted.
  Object? when(
    bool condition,
    Object? Function() value, [
    Object? Function()? otherwise,
  ]) => condition ? value() : (otherwise == null ? missing : otherwise());

  /// [value] unless it is `null` (then omitted).
  Object? whenNotNull(Object? value) => value ?? missing;

  /// The loaded relation [name] (transformed by [value]) or omitted when it
  /// was not eager loaded, so serialising never triggers a lazy query.
  Object? whenLoaded(String name, [Object? Function(Object? related)? value]) {
    final model = resource;
    if (model is! Model || !model.relationLoaded(name)) {
      return missing;
    }
    final related = model.relations[name];
    return value == null ? related : value(related);
  }

  /// The pivot table data when present.
  Object? whenPivotLoaded(Object? Function(Map<String, Object?> pivot) value) {
    final model = resource;
    if (model is! Model || model.pivot == null) {
      return missing;
    }
    return value(model.pivot!);
  }

  /// Merges [values] into the parent map when [condition].
  Object mergeWhen(bool condition, Map<String, Object?> Function() values) =>
      condition ? MergeValue(values()) : missing;

  /// Always merges [values] into the parent map.
  Object merge(Map<String, Object?> values) => MergeValue(values);

  // ---------------------------------------------------------------------------
  // Serialisation
  // ---------------------------------------------------------------------------

  /// Resolved attributes: missing values dropped, merges flattened, nested
  /// resources resolved.
  Map<String, Object?> resolve([Request? request]) =>
      _filter(toArray(request), request);

  @override
  Object? toJson() => resolve();

  /// Payload with wrapper, `withMeta` and `additional` data.
  Map<String, Object?> toPayload([Request? request]) {
    final data = resolve(request);
    final key = ResourceWrapping.key;
    final meta = _filter(withMeta(request), request);
    final payload = key == null || data.containsKey(key)
        ? <String, Object?>{...data}
        : <String, Object?>{key: data};
    return <String, Object?>{
      ...payload,
      ...meta,
      ..._filter(_additional, request),
    };
  }

  @override
  Response toResponse(Request request) {
    final created = resource is Model && (resource as Model).wasRecentlyCreated;
    return Response.json(
      toPayload(request),
      status: _status ?? (created ? 201 : 200),
      headers: _headers,
    );
  }

  /// Wraps [items] (an `Iterable` or any paginator) with [factory].
  static ResourceCollection<T> collection<T>(
    Object items,
    JsonResource<T> Function(T item) factory,
  ) => ResourceCollection<T>(items, factory);
}

Map<String, Object?> _filter(Map<String, Object?> data, Request? request) {
  final result = <String, Object?>{};
  for (final entry in data.entries) {
    final value = entry.value;
    if (value is MissingValue) {
      continue;
    }
    if (value is MergeValue) {
      result.addAll(_filter(value.values, request));
      continue;
    }
    result[entry.key] = _resolveValue(value, request);
  }
  return result;
}

Object? _resolveValue(Object? value, Request? request) => switch (value) {
  JsonResource<Object?>() => value.resolve(request),
  ResourceCollection<Object?>() => value.resolveItems(request),
  Map<String, Object?>() => _filter(value, request),
  List<Object?>() => [
    for (final v in value)
      if (v is! MissingValue) _resolveValue(v, request),
  ],
  _ => value,
};

/// A collection of resources; paginators add Laravel's `links` and `meta`.
final class ResourceCollection<T> implements JsonSerializable, Responsable {
  ResourceCollection(this.source, this.factory) {
    if (source is! Iterable<T> &&
        source is! LengthAwarePaginator<T> &&
        source is! SimplePaginator<T> &&
        source is! CursorPaginator<T>) {
      throw ArgumentError.value(
        source,
        'source',
        'Expected an Iterable<$T> or a paginator of $T.',
      );
    }
  }

  final Object source;
  final JsonResource<T> Function(T item) factory;
  final Map<String, Object?> _additional = <String, Object?>{};
  int? _status;

  List<T> get items => switch (source) {
    final LengthAwarePaginator<T> page => page.items,
    final SimplePaginator<T> page => page.items,
    final CursorPaginator<T> page => page.items,
    final Iterable<T> list => list.toList(),
    _ => const [],
  };

  ResourceCollection<T> additional(Map<String, Object?> data) {
    _additional.addAll(data);
    return this;
  }

  ResourceCollection<T> withStatus(int status) {
    _status = status;
    return this;
  }

  /// Every item resolved.
  List<Map<String, Object?>> resolveItems([Request? request]) => [
    for (final item in items) factory(item).resolve(request),
  ];

  @override
  Object? toJson() => resolveItems();

  bool get isPaginated => source is! Iterable<T>;

  /// `{data, links, meta}` for paginators; `{data}` (or a bare list when
  /// wrapping is disabled) otherwise.
  Object toPayload([Request? request]) {
    final data = resolveItems(request);
    final extra = <String, Object?>{..._additional};
    switch (source) {
      case final LengthAwarePaginator<T> page:
        return <String, Object?>{
          'data': data,
          'links': <String, Object?>{
            'first': page.url(1),
            'last': page.url(page.lastPage),
            'prev': page.previousPageUrl,
            'next': page.nextPageUrl,
          },
          'meta': <String, Object?>{
            'current_page': page.currentPage,
            'from': page.from,
            'last_page': page.lastPage,
            'links': page.links,
            'path': page.path,
            'per_page': page.perPage,
            'to': page.to,
            'total': page.total,
          },
          ...extra,
        };
      case final SimplePaginator<T> page:
        return <String, Object?>{
          'data': data,
          'links': <String, Object?>{
            'first': page.url(1),
            'last': null,
            'prev': page.previousPageUrl,
            'next': page.nextPageUrl,
          },
          'meta': <String, Object?>{
            'current_page': page.currentPage,
            'from': data.isEmpty
                ? null
                : (page.currentPage - 1) * page.perPage + 1,
            'path': page.path,
            'per_page': page.perPage,
            'to': data.isEmpty
                ? null
                : (page.currentPage - 1) * page.perPage + data.length,
          },
          ...extra,
        };
      case final CursorPaginator<T> page:
        return <String, Object?>{
          'data': data,
          'links': <String, Object?>{
            'first': null,
            'last': null,
            'prev': page.previousPageUrl,
            'next': page.nextPageUrl,
          },
          'meta': <String, Object?>{
            'path': page.path,
            'per_page': page.perPage,
            'next_cursor': page.nextCursor?.encode(),
            'prev_cursor': page.previousCursor?.encode(),
          },
          ...extra,
        };
    }
    final key = ResourceWrapping.key;
    if (key == null && extra.isEmpty) {
      return data;
    }
    return <String, Object?>{key ?? 'data': data, ...extra};
  }

  @override
  Response toResponse(Request request) =>
      Response.json(toPayload(request), status: _status ?? 200);
}
