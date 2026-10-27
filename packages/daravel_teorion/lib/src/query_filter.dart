import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'exceptions.dart';
import 'filters.dart';

/// What a client may ask of one model's listing (laravel-teorion's
/// `QueryFilter`): its filters, and the scopes, relations, counts,
/// aggregates and sorts it may name. Anything else is refused or skipped.
///
/// ```dart
/// final class PostQueryFilter extends QueryFilter<Post> {
///   @override
///   Map<String, Filter> get filters => {
///     'search': Filter.multiLike(['title', 'body']),
///     'status': Filter.enum_('status', PostStatus.values),
///   };
///
///   @override
///   List<String> get allowedSorts => ['created_at', 'title'];
///
///   @override
///   List<String> get defaultSort => ['-created_at'];
/// }
/// ```
abstract class QueryFilter<T extends Model> {
  const QueryFilter();

  Map<String, Filter> get filters;

  /// Scopes of the model's definition a client may call (`?scopes[]=`).
  List<String> get allowedScopes => const [];

  /// Relations a client may eager load (`?withs[]=author`), by full path:
  /// `author` does not let a client reach `author.posts` or anything
  /// deeper; list `author.posts` too when it may.
  List<String> get allowedWiths => const [];

  /// Hidden attributes a client may ask to see (`?visibles[]=email`).
  /// Nothing by default: a model's `hidden` list (password hashes, tokens)
  /// is yours to open, not the client's. laravel-teorion lets a client
  /// un-hide anything; `?hiddens[]=` needs no list, hiding more is harmless.
  List<String> get allowedVisibles => const [];

  /// Columns a client may pick, by relation path (`author`,
  /// `author.country`): `?withs[]=author:id,name` loads only those (and the
  /// keys the relation matches on). A relation without an entry is loaded
  /// whole, and asking it for columns is refused, so no client reaches a
  /// column you did not list.
  Map<String, List<String>> get allowedWithColumns => const {};

  /// Relations a client may count (`?withCounts[]=comments`).
  List<String> get allowedWithCounts => const [];

  /// Columns a client may sort by (`?sort=-created_at,title`).
  List<String> get allowedSorts => const [];

  /// relation → aggregate (`count`, `sum`, `avg`, `min`, `max`) → columns
  /// (`?withAggregates[comments][sum][]=score`).
  Map<String, Map<String, List<String>>> get allowedAggregates => const {};

  /// The sort without a client's (`['-created_at']`).
  List<String> get defaultSort => const [];

  /// Whether `?with_trashed=1` and `?only_trashed=1` apply on soft-deleting
  /// models.
  bool get allowTrashedFilters => true;

  /// Sorts of your own by column name, instead of `ORDER BY column`
  /// (laravel-teorion's `sortByXxx()` methods).
  Map<String, void Function(ModelQuery<T> query, String direction)>
  get customSorts => const {};

  /// Applies the request to [query] (laravel-teorion's `apply()`).
  Future<ModelQuery<T>> apply(ModelQuery<T> query, Request request) =>
      _Pipeline<T>(this, request).run(query);

  /// Rules for a form request (laravel-teorion's `HasQueryFilterRules`):
  /// the listing parameters' shapes plus each filter's rule.
  Map<String, String> get validationRules => {
    ...baseRules,
    for (final MapEntry(key: param, value: filter) in filters.entries)
      filter.readKey(param): filter.validationRule,
  };

  /// The listing parameters every query filter accepts.
  static const Map<String, String> baseRules = {
    'sort': 'nullable|string',
    'order_by': 'nullable|string',
    'order_direction': 'nullable|in:asc,desc',
    'order': 'nullable|array',
    'order_null_bottoms': 'nullable|array',
    'withs': 'nullable|array',
    'withCounts': 'nullable|array',
    'scopes': 'nullable|array',
    'visibles': 'nullable|array',
    'hiddens': 'nullable|array',
    'is_paginate': 'nullable|in:0,1,true,false',
    'per_page': 'nullable|integer|min:1|max:100',
    'max_results': 'nullable|integer|min:1|max:100',
    'with_trashed': 'nullable|in:0,1,true,false',
    'only_trashed': 'nullable|in:0,1,true,false',
    'pagination': 'nullable|string|in:cursor',
    'cursor': 'nullable|string',
  };

  /// The query parameters as OpenAPI 3.1 parameter objects, for an API
  /// reference.
  List<Map<String, Object?>> get openApiParameters => [
    for (final MapEntry(key: param, value: filter) in filters.entries)
      {
        'name': filter.readKey(param),
        'in': 'query',
        'required': filter.isRequired,
        'schema': {'type': 'string'},
      },
    if (allowedSorts.isNotEmpty)
      {
        'name': 'sort',
        'in': 'query',
        'description':
            'Comma-separated; `-` for descending. One of: '
            '${allowedSorts.join(', ')}.',
        'schema': {'type': 'string'},
      },
    if (allowedWiths.isNotEmpty)
      {
        'name': 'withs[]',
        'in': 'query',
        if (allowedWithColumns.isNotEmpty)
          'description':
              'A relation, or `relation:column,column` with columns of: '
              '${[for (final MapEntry(key: path, value: columns) in allowedWithColumns.entries) '$path (${columns.join(', ')})'].join('; ')}.',
        'schema': {
          'type': 'array',
          'items': allowedWithColumns.isEmpty
              ? {'type': 'string', 'enum': allowedWiths}
              : {'type': 'string'},
        },
      },
    if (allowedScopes.isNotEmpty)
      {
        'name': 'scopes[]',
        'in': 'query',
        'schema': {
          'type': 'array',
          'items': {'type': 'string', 'enum': allowedScopes},
        },
      },
    {
      'name': 'is_paginate',
      'in': 'query',
      'schema': {'type': 'boolean'},
    },
    {
      'name': 'per_page',
      'in': 'query',
      'schema': {'type': 'integer', 'minimum': 1, 'maximum': 100},
    },
  ];
}

/// `config/teorion.php`.
final class TeorionConfig implements ConfigSection {
  const TeorionConfig({
    this.defaultPerPage = 10,
    this.maxPerPage = 100,
    this.paginateKey = 'is_paginate',
    this.perPageKey = 'per_page',
    this.maxResultsKey = 'max_results',
    this.paginationModeKey = 'pagination',
    this.cursorPaginationValue = 'cursor',
    this.cursorName = 'cursor',
    this.strict = false,
    this.audit = false,
    this.auditLog = false,
    this.auditSampleRate = 1.0,
    this.fingerprintExcludeKeys = const [
      '_token',
      '_method',
      'page',
      'cursor',
      'signature',
      'expires',
    ],
  });

  factory TeorionConfig.fromEnv(Env env) => TeorionConfig(
    defaultPerPage: env.integer('TEORION_DEFAULT_PER_PAGE', 10),
    maxPerPage: env.integer('TEORION_MAX_PER_PAGE', 100),
    // laravel-teorion: strict on APP_DEBUG.
    strict: env.boolean('TEORION_STRICT', env.boolean('APP_DEBUG', false)),
    audit: env.boolean('TEORION_AUDIT_ENABLED', false),
    auditLog: env.boolean('TEORION_AUDIT_LOG', false),
    auditSampleRate:
        double.tryParse(env.string('TEORION_AUDIT_SAMPLE_RATE', '1.0')) ?? 1.0,
  );

  final int defaultPerPage;

  /// The most rows `?per_page=` or `?max_results=` may ask for
  /// (`TEORION_MAX_PER_PAGE`, 100 like [QueryFilter.baseRules]); more is
  /// cut to it, and a value below 1 falls back to [defaultPerPage], so no
  /// client dumps a table or divides a paginator by zero.
  final int maxPerPage;
  final String paginateKey;
  final String perPageKey;
  final String maxResultsKey;
  final String paginationModeKey;
  final String cursorPaginationValue;
  final String cursorName;

  /// Refuse (400) instead of skipping relations and scopes the filter does
  /// not allow (`TEORION_STRICT`, `APP_DEBUG` by default). Scopes outside
  /// the whitelist and sorts outside [QueryFilter.allowedSorts] are always
  /// refused.
  final bool strict;

  /// [QueryAudited] after every listing (`TEORION_AUDIT_ENABLED`), logged
  /// too with [auditLog] (`TEORION_AUDIT_LOG`).
  final bool audit;
  final bool auditLog;

  /// The share of fingerprints audited, decided by the fingerprint, so one
  /// query is always or never audited (`TEORION_AUDIT_SAMPLE_RATE`).
  final double auditSampleRate;
  final List<String> fingerprintExcludeKeys;

  @override
  String get key => 'teorion';

  @override
  Map<String, Object?> toMap() => {
    'default_per_page': defaultPerPage,
    'max_per_page': maxPerPage,
    'paginate_key': paginateKey,
    'per_page_key': perPageKey,
    'max_results_key': maxResultsKey,
    'pagination_mode_key': paginationModeKey,
    'cursor_pagination_value': cursorPaginationValue,
    'cursor_name': cursorName,
    'strict_mode': strict,
    'audit': {
      'enabled': audit,
      'log': auditLog,
      'sample_rate': auditSampleRate,
    },
    'fingerprint': {
      'algorithm': 'sha256',
      'exclude_keys': fingerprintExcludeKeys,
    },
  };
}

TeorionConfig get _config {
  final config = Container.current.make<ConfigRepository>();
  return config.hasSection<TeorionConfig>()
      ? config.section<TeorionConfig>()
      : const TeorionConfig();
}

final class _Pipeline<T extends Model> {
  _Pipeline(this.declaration, this.request);

  final QueryFilter<T> declaration;
  final Request request;

  Future<ModelQuery<T>> run(ModelQuery<T> query) async {
    await _softDeletes(query);
    await _filters(query);
    await _scopes(query);
    await _withs(query);
    await _withCounts(query);
    await _aggregates(query);
    await _sorts(query);
    return query;
  }

  Future<void> _softDeletes(ModelQuery<T> query) async {
    if (!declaration.allowTrashedFilters || !query.definition.softDeletes) {
      return;
    }
    if (await request.boolean('only_trashed')) {
      query.onlyTrashed();
    } else if (await request.boolean('with_trashed')) {
      query.withTrashed();
    }
  }

  Future<void> _filters(ModelQuery<T> query) async {
    for (final MapEntry(key: param, value: filter)
        in declaration.filters.entries) {
      final key = filter.readKey(param);
      var value = await request.input<Object?>(key);
      if ((value == null || value == '') &&
          !await filter.presentIn(request, param)) {
        if (filter.isRequired) {
          throw RequiredFilterMissingException(key);
        }
        if (!filter.hasDefault) {
          continue;
        }
        value = filter.defaultValue;
      }
      await filter.apply(query, value, param, request);
    }
  }

  static List<Object?> _entries(Object? value) => switch (value) {
    final List<Object?> list => list,
    final Map<Object?, Object?> map => map.values.toList(),
    _ => const [],
  };

  Future<void> _scopes(ModelQuery<T> query) async {
    for (final entry in _entries(await request.input<Object?>('scopes'))) {
      final (name, params, legacy) = switch (entry) {
        final String name => (name, const <String, Object?>{}, true),
        final Map<Object?, Object?> map when map['name'] is String => (
          map['name']! as String,
          {
            // `scopes[0][params]=x` (a string, not a map) is a client's
            // mistake, not a 500: it is read as no parameters.
            for (final MapEntry(:key, :value)
                in switch (map['params']) {
                  final Map<Object?, Object?> params => params,
                  _ => const <Object?, Object?>{},
                }.entries)
              '$key': value,
          },
          false,
        ),
        _ => (null, const <String, Object?>{}, false),
      };
      if (name == null) {
        continue;
      }
      // The whitelist holds whatever the strict mode.
      if (!declaration.allowedScopes.contains(name)) {
        throw DisallowedScopeException(name);
      }
      if (!query.definition.scopes.containsKey(name)) {
        if (_config.strict) {
          throw ScopeMethodNotFoundException(name, query.definition.table);
        }
        continue;
      }
      // The legacy format passes the whole request; the new one only the
      // scope's own parameters.
      query.scope(name, [legacy ? request : _scoped(params)]);
    }
  }

  Request _scoped(Map<String, Object?> params) => Request.fake(
    path: request.path,
    query: {for (final MapEntry(:key, :value) in params.entries) key: '$value'},
  );

  Future<void> _withs(ModelQuery<T> query) async {
    final toLoad = <String>[];
    for (final entry in _entries(await request.input<Object?>('withs'))) {
      final relation = '$entry';
      final colon = relation.indexOf(':');
      final path = (colon < 0 ? relation : relation.substring(0, colon)).trim();
      // The whole path: `author` in the list does not open `author.posts`
      // (every segment is a relation of the one before, loaded whole).
      if (!declaration.allowedWiths.contains(path)) {
        if (_config.strict) {
          throw DisallowedWithException(path);
        }
        continue;
      }
      if (colon < 0) {
        toLoad.add(path);
        continue;
      }
      // Only listed columns, as plain names: nothing the model hides or an
      // expression reaches the SELECT.
      final allowed = declaration.allowedWithColumns[path] ?? const [];
      final columns = [
        for (final column in relation.substring(colon + 1).split(','))
          if (column.trim().isNotEmpty) column.trim(),
      ];
      final refused = columns.isEmpty
          ? '(none)'
          : columns
                .where((c) => !allowed.contains(c) || !_column.hasMatch(c))
                .firstOrNull;
      if (refused != null) {
        if (_config.strict) {
          throw DisallowedWithColumnsException(path, refused);
        }
        continue;
      }
      toLoad.add('$path:${columns.join(',')}');
    }
    if (toLoad.isNotEmpty) {
      query.with_(toLoad);
    }
  }

  static final RegExp _column = RegExp(r'^\w+$');

  Future<void> _withCounts(ModelQuery<T> query) async {
    final counts = [
      for (final entry in _entries(await request.input<Object?>('withCounts')))
        if (declaration.allowedWithCounts.contains('$entry')) '$entry',
    ];
    if (counts.isNotEmpty) {
      query.withCount(counts);
    }
  }

  Future<void> _aggregates(ModelQuery<T> query) async {
    final requested = await request.input<Object?>('withAggregates');
    if (requested is! Map) {
      return;
    }
    for (final MapEntry(key: relation, value: operations)
        in requested.entries) {
      final allowed = declaration.allowedAggregates['$relation'];
      if (allowed == null || operations is! Map) {
        continue;
      }
      for (final MapEntry(key: type, value: columns) in operations.entries) {
        final kind = '$type'.toLowerCase();
        if (!allowed.containsKey(kind)) {
          continue;
        }
        if (kind == 'count') {
          query.withCount('$relation');
          continue;
        }
        for (final column in _entries(
          columns is String ? [columns] : columns,
        )) {
          if (!(allowed[kind] ?? const []).contains('$column')) {
            continue;
          }
          switch (kind) {
            case 'sum':
              query.withSum('$relation', '$column');
            case 'avg':
              query.withAvg('$relation', '$column');
            case 'min':
              query.withMin('$relation', '$column');
            case 'max':
              query.withMax('$relation', '$column');
          }
        }
      }
    }
  }

  Future<void> _sorts(ModelQuery<T> query) async {
    var sorts = await _parseSorts();
    if (sorts.isEmpty) {
      sorts = _parse(declaration.defaultSort);
    }
    final allowed = declaration.allowedSorts;
    // NULLs last, for allowed columns only: laravel-teorion puts this value
    // into orderByRaw unchecked.
    for (final column in _entries(
      await request.input<Object?>('order_null_bottoms'),
    )) {
      if (!allowed.contains('$column')) {
        throw DisallowedSortException('$column');
      }
      final wrapped = Container.current
          .make<DatabaseManager>()
          .grammarFor(query.definition.connection)
          .wrap('$column');
      query.builder.orderByRaw('CASE WHEN $wrapped IS NULL THEN 1 ELSE 0 END');
    }
    for (final MapEntry(key: column, value: direction) in sorts.entries) {
      if (!allowed.contains(column)) {
        throw DisallowedSortException(column);
      }
      final custom = declaration.customSorts[column];
      if (custom != null) {
        custom(query, direction);
      } else {
        query.orderBy(column, direction);
      }
    }
  }

  /// `?sort=-a,b`, else `?order[0][by]=a&order[0][direction]=desc`, else
  /// `?order_by=a&order_direction=desc`.
  Future<Map<String, String>> _parseSorts() async {
    final sort = await request.input<Object?>('sort');
    if (sort != null && '$sort'.isNotEmpty) {
      return _parse('$sort'.split(','));
    }
    final order = await request.input<Object?>('order');
    if (order is List || order is Map) {
      return {
        for (final entry in _entries(order))
          if (entry is Map &&
              entry['by'] != null &&
              '${entry['by']}'.isNotEmpty)
            '${entry['by']}': _direction(entry['direction']),
      };
    }
    final by = await request.input<Object?>('order_by');
    if (by != null && '$by'.isNotEmpty) {
      return {
        '$by': _direction(await request.input<Object?>('order_direction')),
      };
    }
    return const {};
  }

  static String _direction(Object? value) {
    final direction = '${value ?? 'asc'}'.toLowerCase();
    return direction == 'desc' ? 'desc' : 'asc';
  }

  static Map<String, String> _parse(Iterable<String> columns) => {
    for (final raw in columns)
      if (raw.trim().isNotEmpty)
        raw.trim().replaceFirst(RegExp('^-+'), ''): raw.trim().startsWith('-')
            ? 'desc'
            : 'asc',
  };
}

// ---------------------------------------------------------------------
// Resolution, terminals and the audit.

/// The query filters by model, registered with `withQueryFilters`
/// (laravel-teorion's convention, without reflection).
final class QueryFilterRegistry {
  QueryFilterRegistry(this._factories);

  final Map<Type, QueryFilter<Model> Function()> _factories;

  QueryFilter<T>? of<T extends Model>() =>
      _factories[T]?.call() as QueryFilter<T>?;
}

/// A model that names its own query filter (laravel-teorion's
/// `$queryFilter` / `newQueryFilter()`).
base mixin Filterable<T extends Model> on Model {
  QueryFilter<T> newQueryFilter();
}

/// How a listing ended, in [QueryAudited] (`paginate`, `cursor`,
/// `collection`, `find`).
typedef TerminalMode = String;

/// After a listing, with `TEORION_AUDIT_ENABLED` (laravel-teorion's
/// `QueryAudited`): [record] holds `fingerprint`, `filter_class`,
/// `model_class`, `terminal_mode`, `limit`, `result_count`, `duration_ms`
/// and `user_id`.
final class QueryAudited {
  const QueryAudited(this.record);

  final Map<String, Object?> record;
}

/// A deterministic hash of a listing's intent: the filter, the model and
/// the request's parameters with their keys sorted (laravel-teorion's
/// `QueryFingerprint`, SHA-256).
final class QueryFingerprint {
  const QueryFingerprint(this.hash, this.payload);

  final String hash;
  final Map<String, Object?> payload;
  String get algorithm => 'sha256';

  static Future<QueryFingerprint> of(
    QueryFilter<Model> filter,
    ModelDefinition<Model> definition,
    Request request,
  ) async {
    final exclude = _config.fingerprintExcludeKeys.toSet();
    final parameters = <String, Object?>{
      for (final MapEntry(:key, :value) in (await request.all()).entries)
        if (!exclude.contains(key)) key: value,
    };
    final payload = <String, Object?>{
      'filter_class': '${filter.runtimeType}',
      'model_class': definition.morphClass,
      'table': definition.table,
      'connection': definition.connection ?? 'default',
      'parameters': _sorted(parameters),
    };
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return QueryFingerprint(hash, payload);
  }

  static Object? _sorted(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final key in map.keys.map((k) => '$k').toList()..sort())
        key: _sorted(map[key]),
    },
    final List<Object?> list => [for (final item in list) _sorted(item)],
    _ => value,
  };
}

/// `Post.query().filter(request)` and friends.
extension FilterableQuery<T extends Model> on ModelQuery<T> {
  QueryFilter<T> _resolve(QueryFilter<T>? explicit) {
    if (explicit != null) {
      return explicit;
    }
    final model = definition.factory();
    if (model is Filterable<T>) {
      return (model as Filterable<T>).newQueryFilter();
    }
    final container = Container.current;
    final registered = container.bound<QueryFilterRegistry>()
        ? container.make<QueryFilterRegistry>().of<T>()
        : null;
    return registered ?? (throw QueryFilterNotFoundException(T));
  }

  /// Applies the model's query filter (or [filter]) and returns the query,
  /// to go on with `.get()`, `.first()`, ... (laravel-teorion's
  /// `filter()`).
  Future<ModelQuery<T>> filter(
    Request request, [
    QueryFilter<T>? filter,
  ]) async => _resolve(filter).apply(this, request);

  /// Filters, then ends as the request asks (laravel-teorion's
  /// `filterAndPaginate()`): a [CursorPaginator] for `?pagination=cursor`,
  /// a [LengthAwarePaginator] for `?is_paginate=1`, else a
  /// [ModelCollection] (limited by `?max_results=` or `?per_page=`).
  Future<Object> filterAndPaginate(
    Request request, [
    QueryFilter<T>? filter,
  ]) async {
    final watch = Stopwatch()..start();
    final config = _config;
    final declaration = _resolve(filter);
    await declaration.apply(this, request);
    final limit = await _limit(request, config);
    final cursor =
        '${await request.input<Object?>(config.paginationModeKey) ?? ''}' ==
        config.cursorPaginationValue;
    final paginate = await request.boolean(config.paginateKey);
    final Object result;
    final ModelCollection<T> items;
    final String mode;
    if (cursor) {
      final page = await cursorPaginate(
        perPage: limit,
        cursorName: config.cursorName,
      );
      (result, items, mode) = (page, ModelCollection<T>(page.items), 'cursor');
    } else if (paginate) {
      final page = await this.paginate(perPage: limit);
      (result, items, mode) = (
        page,
        ModelCollection<T>(page.items),
        'paginate',
      );
    } else {
      if (await request.has(config.maxResultsKey) ||
          await request.has(config.perPageKey)) {
        this.limit(limit);
      }
      final all = await get();
      (result, items, mode) = (all, all, 'collection');
    }
    await _visibility(items, request, declaration, config);
    await _audit(declaration, request, mode, limit, items.length, watch);
    return result;
  }

  /// One filtered model by [id]: the primary key for a number, else the
  /// `uuid` column (laravel-teorion's `findFiltered()`).
  Future<T?> findFiltered(
    Request request,
    Object id, [
    QueryFilter<T>? filter,
  ]) async {
    final watch = Stopwatch()..start();
    final declaration = _resolve(filter);
    await declaration.apply(this, request);
    final key = num.tryParse('$id') != null ? definition.primaryKey : 'uuid';
    final model = await where(key, id).first();
    if (model != null) {
      await _visibility(
        ModelCollection<T>([model]),
        request,
        declaration,
        _config,
      );
    }
    await _audit(declaration, request, 'find', 1, model == null ? 0 : 1, watch);
    return model;
  }

  static Future<int> _limit(Request request, TeorionConfig config) async {
    final value =
        await request.input<Object?>(config.maxResultsKey) ??
        await request.input<Object?>(config.perPageKey);
    final asked = int.tryParse('${value ?? ''}');
    // Below 1 is not a size (the builder reads a negative limit as none,
    // and a paginator divides by it); above the cap is cut to it.
    if (asked == null || asked < 1) {
      return config.defaultPerPage;
    }
    return asked > config.maxPerPage ? config.maxPerPage : asked;
  }

  static Future<void> _visibility(
    ModelCollection<Model> items,
    Request request,
    QueryFilter<Model> declaration,
    TeorionConfig config,
  ) async {
    List<String> names(Object? value) => [
      for (final item in _Pipeline._entries(value)) '$item',
    ];
    final asked = names(await request.input<Object?>('visibles'));
    final hidden = names(await request.input<Object?>('hiddens'));
    final allowed = declaration.allowedVisibles;
    final visible = <String>[];
    for (final name in asked) {
      if (allowed.contains(name)) {
        visible.add(name);
      } else if (config.strict) {
        throw DisallowedVisibleException(name);
      }
    }
    if (visible.isNotEmpty) {
      items.makeVisible(visible);
    }
    if (hidden.isNotEmpty) {
      items.makeHidden(hidden);
    }
  }

  Future<void> _audit(
    QueryFilter<T> declaration,
    Request request,
    TerminalMode mode,
    int limit,
    int count,
    Stopwatch watch,
  ) async {
    final config = _config;
    if (!config.audit) {
      return;
    }
    final fingerprint = await QueryFingerprint.of(
      declaration,
      definition,
      request,
    );
    final rate = config.auditSampleRate;
    if (rate < 1.0 &&
        (rate <= 0.0 ||
            int.parse(fingerprint.hash.substring(0, 8), radix: 16) /
                    0xFFFFFFFF >
                rate)) {
      return;
    }
    Authenticatable? user;
    try {
      user = await Auth.user<Authenticatable>();
    } on StateError {
      user = null; // no auth guard in this application
    }
    final record = {
      'fingerprint': {
        'hash': fingerprint.hash,
        'algorithm': fingerprint.algorithm,
        'payload': fingerprint.payload,
      },
      'filter_class': '${declaration.runtimeType}',
      'model_class': definition.morphClass,
      'terminal_mode': mode,
      'limit': limit,
      'result_count': count,
      'duration_ms': watch.elapsedMicroseconds / 1000,
      'user_id': user?.authIdentifier,
    };
    await Event.dispatch(QueryAudited(record));
    if (config.auditLog) {
      Log.info('teorion.query_audited', record);
    }
  }
}
