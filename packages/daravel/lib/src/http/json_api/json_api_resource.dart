import '../../database/orm/model.dart';
import '../../database/orm/model_collection.dart';
import '../../database/orm/relations.dart';
import '../request.dart';
import '../resources.dart';
import '../response.dart';
import 'json_api_request.dart';

const String _mediaType = 'application/vnd.api+json';

/// A relation a [JsonApiResource] can expose. There is no `toResource` without
/// reflection, so it names the resource for its models.
final class JsonApiRelationship<R extends Model> {
  JsonApiRelationship(this._wrap, {this.resolver});

  final JsonApiResource<R> Function(R model) _wrap;

  /// Replaces the loaded relation.
  final Object? Function(Model parent)? resolver;

  JsonApiResource<Object?> wrap(Model model) => _wrap(model as R);

  bool get isCustom => resolver != null;

  Object? resolve(Model parent) => resolver!(parent);
}

/// An entry of `included`, before duplicates go.
final class _Include {
  _Include(this.resource, this.type, this.id, {required this.unique});

  final JsonApiResource<Object?> resource;
  final String type;
  final String id;

  /// False for `BelongsToMany`: the same row with other pivot data is another
  /// entry.
  final bool unique;
}

/// Laravel 13's `JsonApiResource`: a [JsonResource] in the JSON:API v1.1 shape.
///
/// ```dart
/// final class PostResource extends JsonApiResource<Post> {
///   PostResource(super.resource);
///
///   @override
///   String toType(Request? request) => 'posts';
///
///   @override
///   Map<String, Object?> toArray(Request? request) => {
///     'title': resource.title,
///   };
///
///   @override
///   Map<String, JsonApiRelationship<Model>> toRelationships(Request? request) =>
///       {'author': JsonApiRelationship<User>(UserResource.new)};
/// }
/// ```
///
/// `?fields[posts]=title` narrows the attributes. A relationship shows when
/// `?include=author` asks for it. Returned from a route, the kernel loads what
/// the query asks for first; anywhere else, what is not loaded is left out.
abstract class JsonApiResource<T> extends JsonResource<T>
    implements PreparedResponsable {
  JsonApiResource(super.resource);

  /// The top-level `jsonapi` member, from [configure].
  static Map<String, Object?> jsonApiInformation = const {};

  static int _depth = 5;

  /// Numbers the entries that must not count as duplicates.
  static int _sequence = 0;

  /// How deep `?include=` reaches.
  static int get relationshipDepth => _depth;

  static void maxRelationshipDepth(int depth) {
    _depth = depth < 0 ? 0 : depth;
  }

  /// Sets the `jsonapi` member of every response.
  static void configure({
    String? version,
    List<String> ext = const [],
    List<String> profile = const [],
    Map<String, Object?> meta = const {},
  }) {
    jsonApiInformation = {
      'version': ?version,
      if (ext.isNotEmpty) 'ext': ext,
      if (profile.isNotEmpty) 'profile': profile,
      if (meta.isNotEmpty) 'meta': meta,
    };
  }

  /// The `type` member. No default: naming it after the class needs mirrors.
  String toType(Request? request);

  /// The `id` member; a model's key by default.
  String? toId(Request? request) => null;

  /// The `attributes` member; [toArray] by default.
  Map<String, Object?> toAttributes(Request? request) => toArray(request);

  @override
  Map<String, Object?> toArray(Request? request) => const {};

  Map<String, JsonApiRelationship<Model>> toRelationships(Request? request) =>
      const {};

  Map<String, Object?> toLinks(Request? request) => const {};

  Map<String, Object?> toMeta(Request? request) => const {};

  /// Relations a parent asked for through `a.b`; null reads the query.
  List<String>? _requested;

  /// Set on included resources: what is loaded shows as well.
  bool _includesLoaded = false;

  List<_Include>? _includes;
  Map<String, Object?> _identifiers = const {};

  String _id(Request? request) {
    final id = toId(request);
    if (id != null) {
      return id;
    }
    final model = resource;
    if (model is Model) {
      return '${model.key}';
    }
    throw StateError('$runtimeType needs a toId: its resource is no model.');
  }

  List<String> _requestedRelations(JsonApiRequest query, [String? relation]) {
    final requested = _requested;
    if (requested == null) {
      if (_includesLoaded) {
        final model = resource;
        return relation == null && model is Model
            ? model.relations.keys.toList()
            : const [];
      }
      return query.sparseIncluded(relation);
    }
    if (relation == null) {
      final model = resource;
      return <String>{
        for (final name in requested) name.split('.').first,
        if (_includesLoaded && model is Model) ...model.relations.keys,
      }.toList();
    }
    return [
      for (final name in requested)
        if (name.startsWith('$relation.')) name.substring(relation.length + 1),
    ];
  }

  void _compile(JsonApiRequest query) {
    if (_includes != null) {
      return;
    }
    final includes = _includes = <_Include>[];
    final model = resource;
    if (model is! Model) {
      return;
    }
    final identifiers = <String, Object?>{};
    final sparse = _requestedRelations(query);
    final relationships = toRelationships(query.request);
    for (final MapEntry(key: name, value: relationship)
        in relationships.entries) {
      if (!sparse.contains(name)) {
        continue;
      }
      final Object? related;
      if (relationship.isCustom) {
        related = relationship.resolve(model);
      } else if (model.relationLoaded(name)) {
        related = model.relations[name];
      } else {
        continue;
      }
      final nested = _requestedRelations(query, name);
      Map<String, Object?> identify(Model child, {required bool unique}) {
        final included = relationship.wrap(child).._requested = nested;
        if (nested.isNotEmpty) {
          included
            .._includesLoaded = true
            .._compile(query);
        }
        final type = included.toType(query.request);
        final id = included._id(query.request);
        includes.add(_Include(included, type, id, unique: unique));
        return {'id': id, 'type': type};
      }

      identifiers[name] = switch (related) {
        final Model child => {'data': identify(child, unique: true)},
        final Iterable<Object?> children => {
          'data': [
            for (final child in children.whereType<Model>())
              identify(
                child,
                unique: model.modelDefinition.relation(
                  name,
                ) is! BelongsToMany<Model>,
              ),
          ],
        },
        _ => {'data': null},
      };
    }
    _identifiers = identifiers;
  }

  /// The resource object.
  @override
  Map<String, Object?> resolve([Request? request]) {
    final query = JsonApiRequest.of(request);
    final type = toType(request);
    var attributes = filtered(toAttributes(request), request);
    if (query.hasSparseFieldset(type)) {
      final fields = query.sparseFields(type);
      attributes = {
        for (final entry in attributes.entries)
          if (fields.contains(entry.key)) entry.key: entry.value,
      };
    }
    _compile(query);
    final links = toLinks(request);
    final meta = toMeta(request);
    return {
      'id': _id(request),
      'type': type,
      if (attributes.isNotEmpty) 'attributes': attributes,
      if (_identifiers.isNotEmpty) 'relationships': _identifiers,
      if (links.isNotEmpty) 'links': links,
      if (meta.isNotEmpty) 'meta': meta,
    };
  }

  /// Breadth first, each object once per type: `chaperone`d relations loop.
  List<(String, Map<String, Object?>)> _resolveIncludes(JsonApiRequest query) {
    if (resource is! Model) {
      return const [];
    }
    _compile(query);
    final results = <(String, Map<String, Object?>)>[];
    final queue = [..._includes!];
    final visited = Map<Object?, Set<String>>.identity()
      ..[resource] = {toType(query.request)};
    for (var index = 0; index < queue.length; index++) {
      final include = queue[index];
      final seen = visited.putIfAbsent(
        include.resource.resource,
        () => <String>{},
      );
      if (!seen.add(include.type)) {
        continue;
      }
      final object = (include.resource.._includesLoaded = true).resolve(
        query.request,
      );
      queue.addAll(include.resource._includes ?? const []);
      final key = '${include.id}:${include.type}';
      results.add((
        include.unique ? key : '$key:${_sequence++}',
        {
          'id': include.id,
          'type': include.type,
          for (final member in const [
            'attributes',
            'relationships',
            'links',
            'meta',
          ])
            if (object[member] != null) member: object[member],
        },
      ));
    }
    return results;
  }

  static List<Map<String, Object?>> _unique(
    Iterable<(String, Map<String, Object?>)> included,
  ) {
    final seen = <String>{};
    return [
      for (final (key, object) in included)
        if (seen.add(key)) object,
    ];
  }

  @override
  Future<void> prepare(Request request) => _loadRequested([this], request);

  /// Loads what the query asks for, a level at a time, for a whole page.
  static Future<void> _loadRequested(
    List<JsonApiResource<Object?>> resources,
    Request request,
  ) async {
    if (resources.isEmpty) {
      return;
    }
    final query = JsonApiRequest.of(request);
    final first = resources.first;
    await _loadMissing(
      query,
      [
        for (final resource in resources)
          if (resource.resource case final Model model) model,
      ],
      first,
      [
        for (final name in first._requestedRelations(query)) ...[
          name,
          for (final nested in first._requestedRelations(query, name))
            '$name.$nested',
        ],
      ],
    );
  }

  static Future<void> _loadMissing(
    JsonApiRequest query,
    List<Model> models,
    JsonApiResource<Object?> sample,
    List<String> requested,
  ) async {
    if (models.isEmpty) {
      return;
    }
    final relationships = sample.toRelationships(query.request);
    final tops = {for (final name in requested) name.split('.').first};
    final loadable = [
      for (final name in tops)
        if (relationships[name] case final JsonApiRelationship<Model> found
            when !found.isCustom &&
                models.first.modelDefinition.relation(name) != null)
          name,
    ];
    await ModelCollection<Model>(models).loadMissing(loadable);
    for (final name in loadable) {
      final nested = [
        for (final item in requested)
          if (item.startsWith('$name.')) item.substring(name.length + 1),
      ];
      if (nested.isEmpty) {
        continue;
      }
      final byDefinition = <Object, List<Model>>{};
      for (final model in models) {
        final children = switch (model.relations[name]) {
          final Model child => [child],
          final Iterable<Object?> many => many.whereType<Model>(),
          _ => const <Model>[],
        };
        for (final child in children) {
          byDefinition.putIfAbsent(child.modelDefinition, () => []).add(child);
        }
      }
      for (final group in byDefinition.values) {
        await _loadMissing(
          query,
          group,
          relationships[name]!.wrap(group.first),
          nested,
        );
      }
    }
  }

  @override
  Response toResponse(Request request) =>
      super.toResponse(request)..headers.set('content-type', _mediaType);

  @override
  Map<String, Object?> toPayload([Request? request]) {
    final query = JsonApiRequest.of(request);
    final data = resolve(request);
    final included = _unique(_resolveIncludes(query));
    return {
      'data': data,
      if (included.isNotEmpty) 'included': included,
      if (jsonApiInformation.isNotEmpty) 'jsonapi': jsonApiInformation,
      ...filtered(additionalData, request),
    };
  }

  /// Wraps [items], an `Iterable` or any paginator, with [factory].
  static JsonApiCollection<T> collection<T>(
    Object items,
    JsonApiResource<T> Function(T item) factory,
  ) => JsonApiCollection<T>(items, factory);
}

/// Resources under one `data`; paginators add Laravel's `links` and `meta`.
final class JsonApiCollection<T>
    implements JsonSerializable, PreparedResponsable {
  JsonApiCollection(Object source, JsonApiResource<T> Function(T item) factory)
    : _source = ResourceCollection<T>(source, factory),
      _factory = factory;

  final ResourceCollection<T> _source;
  final JsonApiResource<T> Function(T item) _factory;
  final Map<String, Object?> _additional = <String, Object?>{};
  int? _status;

  late final List<JsonApiResource<T>> _resources = [
    for (final item in _source.items) _factory(item),
  ];

  JsonApiCollection<T> additional(Map<String, Object?> data) {
    _additional.addAll(data);
    return this;
  }

  JsonApiCollection<T> withStatus(int status) {
    _status = status;
    return this;
  }

  List<Map<String, Object?>> resolveItems([Request? request]) => [
    for (final resource in _resources) resource.resolve(request),
  ];

  @override
  Object? toJson() => resolveItems();

  @override
  Future<void> prepare(Request request) =>
      JsonApiResource._loadRequested(_resources, request);

  Map<String, Object?> toPayload([Request? request]) {
    final query = JsonApiRequest.of(request);
    final data = resolveItems(request);
    final included = JsonApiResource._unique([
      for (final resource in _resources) ...resource._resolveIncludes(query),
    ]);
    return {
      'data': data,
      ...?_source.paginationMembers(),
      if (included.isNotEmpty) 'included': included,
      if (JsonApiResource.jsonApiInformation.isNotEmpty)
        'jsonapi': JsonApiResource.jsonApiInformation,
      ..._additional,
    };
  }

  @override
  Response toResponse(Request request) =>
      Response.json(toPayload(request), status: _status ?? 200)
        ..headers.set('content-type', _mediaType);
}
