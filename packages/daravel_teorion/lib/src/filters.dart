import 'dart:async';

import 'package:daravel/daravel.dart';

/// One declared request filter of a [QueryFilter]: applied when its
/// parameter is in the request (laravel-teorion's `BaseFilter`).
///
/// ```dart
/// 'search': Filter.multiLike(['title', 'body']).alias('q'),
/// 'is_active': Filter.boolean().withDefault(true),
/// 'tenant_id': Filter.exact().required(),
/// ```
abstract base class Filter {
  Filter([this.column]);

  /// The column, when it differs from the parameter.
  final String? column;

  String? _alias;
  Object? _default;
  bool _hasDefault = false;
  bool _required = false;

  /// Applies the filter for [value] of parameter [param].
  FutureOr<void> apply(
    ModelQuery<Model> query,
    Object? value,
    String param,
    Request request,
  );

  /// Whether the request asks for this filter through parameters of its own
  /// (a range's `_min` / `_max`), when the declared one is missing.
  Future<bool> presentIn(Request request, String param) async => false;

  /// The rule `queryFilterRules` gives this parameter.
  String get validationRule => 'nullable';

  String resolveColumn(String param) => column ?? param;

  /// Reads the value from `?<alias>=` instead of the declared name.
  Filter alias(String name) {
    _alias = name;
    return this;
  }

  /// The value used when the parameter is missing (laravel-teorion's
  /// `default()`).
  Filter withDefault(Object? value) {
    _default = value;
    _hasDefault = true;
    return this;
  }

  /// A missing parameter answers 400 ([RequiredFilterMissingException]).
  Filter required([bool required = true]) {
    _required = required;
    return this;
  }

  String readKey(String declared) => _alias ?? declared;
  bool get hasDefault => _hasDefault;
  Object? get defaultValue => _default;
  bool get isRequired => _required;

  // -------------------------------------------------------------------
  // The built-in filter types, as laravel-teorion's `Filter::` factory.

  /// `WHERE col = ?`.
  static Filter exact([String? column]) => _Exact(column);

  /// `WHERE col LIKE %?%`.
  static Filter like([String? column]) => _Like(column);

  /// `WHERE (col1 LIKE %?% OR col2 LIKE %?%)`.
  static Filter multiLike(List<String> columns) => _MultiLike(columns);

  /// `WHERE col = 1` or `0` (`true`, `1`, `on`, `yes` are true).
  static Filter boolean([String? column]) => _Boolean(column);

  /// `WHERE col IS NOT NULL` for a true value, `IS NULL` otherwise.
  static Filter null_([String? column]) => _Null(column);

  /// `WHERE col = ?` for one of [values] (enum values use their `name`);
  /// another value matches nothing.
  static Filter enum_([String? column, Iterable<Object>? values]) =>
      _Enum(column, values);

  /// `WHERE col IN (...)` from `a,b,c` or `col[]=a&col[]=b`.
  static Filter in_([String? column]) => _In(column);

  /// `WHERE DATE(col) = ?`.
  static Filter date([String? column]) => _Date(column);

  /// `WHERE col BETWEEN ? AND ?` from [fromParam] and [toParam], or one
  /// side of it.
  static Filter dateRange([
    String? column,
    String fromParam = 'start_date',
    String toParam = 'end_date',
  ]) => _DateRange(column, fromParam, toParam);

  /// `WHERE col BETWEEN ? AND ?` from `a,b` or a two-element list.
  static Filter between([String? column]) => _Between(column);

  /// `WHERE col >= ? AND col <= ?` from `<param>_min` and `<param>_max`.
  static Filter range([String? column]) => _Range(column);

  /// `WHERE col > ?` (`>=` with [orEqual]).
  static Filter gt([String? column, bool orEqual = false]) =>
      _Compare(column, orEqual ? '>=' : '>');

  /// `WHERE col < ?` (`<=` with [orEqual]).
  static Filter lt([String? column, bool orEqual = false]) =>
      _Compare(column, orEqual ? '<=' : '<');

  /// `WHERE EXISTS (relation)` for a true value, `NOT EXISTS` otherwise.
  static Filter has(String relation) => _Has(relation);

  /// `JSON_CONTAINS(col, ?)` on every database.
  static Filter jsonContains([String? column]) => _JsonContains(column);

  /// Your own logic.
  static Filter callback(FilterCallback callback) => _Callback(callback);

  /// The model's scope [name] (`scopes:` of its definition), given the
  /// request.
  static Filter scope(String name) => _Scope(name);

  /// A filter type registered with [FilterMacroRegistry.register].
  static Filter macro(String name) => _Callback(FilterMacroRegistry.get(name));
}

/// `(query, value, param, request)` of [Filter.callback] and macros.
typedef FilterCallback = FutureOr<void> Function(
  ModelQuery<Model> query,
  Object? value,
  String param,
  Request request,
);

/// Custom filter types, shared by every [QueryFilter]
/// (laravel-teorion's `FilterMacroRegistry`).
abstract final class FilterMacroRegistry {
  static final Map<String, FilterCallback> _macros = {};

  static void register(String name, FilterCallback callback) =>
      _macros[name] = callback;

  static bool has(String name) => _macros.containsKey(name);

  static FilterCallback get(String name) =>
      _macros[name] ??
      (throw StateError('Filter macro [$name] is not registered.'));

  static void clear() => _macros.clear();
}

bool _truthy(Object? value) => switch (value) {
  final bool value => value,
  final num value => value != 0,
  final String value => const {
    '1',
    'true',
    'on',
    'yes',
  }.contains(value.trim().toLowerCase()),
  _ => false,
};

bool _filled(Object? value) => value != null && '$value'.isNotEmpty;

List<Object?> _list(Object? value) => switch (value) {
  final List<Object?> list => list,
  final Map<Object?, Object?> map => map.values.toList(),
  _ => '$value'.split(','),
};

final class _Exact extends Filter {
  _Exact(super.column);

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      query.where(resolveColumn(param), value);
}

final class _Like extends Filter {
  _Like(super.column);

  @override
  String get validationRule => 'nullable|string|max:255';

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      query.where(resolveColumn(param), 'like', '%$value%');
}

final class _MultiLike extends Filter {
  _MultiLike(this.columns);

  final List<String> columns;

  @override
  String get validationRule => 'nullable|string|max:255';

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) {
    final search = '%$value%';
    query.where((QueryBuilder q) {
      for (final (index, column) in columns.indexed) {
        if (index == 0) {
          q.where(column, 'like', search);
        } else {
          q.orWhere(column, 'like', search);
        }
      }
    });
  }
}

final class _Boolean extends Filter {
  _Boolean(super.column);

  @override
  String get validationRule => 'nullable|in:0,1,true,false';

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      query.where(resolveColumn(param), _truthy(value) ? 1 : 0);
}

final class _Null extends Filter {
  _Null(super.column);

  @override
  String get validationRule => 'nullable|in:0,1,true,false';

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) {
    final column = resolveColumn(param);
    _truthy(value) ? query.whereNotNull(column) : query.whereNull(column);
  }
}

final class _Enum extends Filter {
  _Enum(super.column, Iterable<Object>? values)
    : values = values?.map((v) => v is Enum ? v.name : '$v').toList();

  final List<String>? values;

  @override
  String get validationRule =>
      values == null ? 'nullable|string' : 'nullable|in:${values!.join(',')}';

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) {
    final allowed = values;
    if (allowed != null && !allowed.contains('$value')) {
      query.builder.whereRaw('1 = 0'); // an unknown value matches nothing
      return;
    }
    query.where(resolveColumn(param), value);
  }
}

final class _In extends Filter {
  _In(super.column);

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      query.whereIn(resolveColumn(param), [
        for (final item in _list(value))
          if (item != null && '$item'.isNotEmpty) item,
      ]);
}

final class _Date extends Filter {
  _Date(super.column);

  @override
  String get validationRule => 'nullable|date';

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      query.whereDate(resolveColumn(param), '=', value);
}

final class _DateRange extends Filter {
  _DateRange(super.column, this.fromParam, this.toParam);

  final String fromParam;
  final String toParam;

  // laravel-teorion only runs it when the declared parameter is there too.
  @override
  Future<bool> presentIn(Request request, String param) async =>
      _filled(await request.input<Object?>(fromParam)) ||
      _filled(await request.input<Object?>(toParam));

  @override
  String get validationRule => 'nullable|date';

  @override
  Future<void> apply(
    ModelQuery<Model> query,
    Object? value,
    String param,
    Request request,
  ) async {
    final column = resolveColumn(param);
    final from = await request.input<Object?>(fromParam);
    final to = await request.input<Object?>(toParam);
    final hasFrom = from != null && '$from'.isNotEmpty;
    final hasTo = to != null && '$to'.isNotEmpty;
    if (hasFrom && hasTo) {
      query.whereBetween(column, from, to);
    } else if (hasFrom) {
      query.whereDate(column, '>=', from);
    } else if (hasTo) {
      query.whereDate(column, '<=', to);
    }
  }
}

final class _Between extends Filter {
  _Between(super.column);

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) {
    final bounds = value is List || value is Map
        ? _list(value)
        : '$value'.split(',').take(2).toList();
    if (bounds.length == 2) {
      query.whereBetween(resolveColumn(param), bounds[0], bounds[1]);
    }
  }
}

final class _Range extends Filter {
  _Range(super.column);

  @override
  Future<bool> presentIn(Request request, String param) async =>
      _filled(await request.input<Object?>('${param}_min')) ||
      _filled(await request.input<Object?>('${param}_max'));

  @override
  Future<void> apply(
    ModelQuery<Model> query,
    Object? value,
    String param,
    Request request,
  ) async {
    final column = resolveColumn(param);
    final min = await request.input<Object?>('${param}_min');
    final max = await request.input<Object?>('${param}_max');
    if (min != null && '$min'.isNotEmpty) {
      query.where(column, '>=', min);
    }
    if (max != null && '$max'.isNotEmpty) {
      query.where(column, '<=', max);
    }
  }
}

final class _Compare extends Filter {
  _Compare(super.column, this.operator);

  final String operator;

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      query.where(resolveColumn(param), operator, value);
}

final class _Has extends Filter {
  _Has(this.relation);

  final String relation;

  @override
  String get validationRule => 'nullable|in:0,1,true,false';

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      _truthy(value)
      ? query.whereHas(relation)
      : query.whereDoesntHave(relation);
}

final class _JsonContains extends Filter {
  _JsonContains(super.column);

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) =>
      query.builder.whereJsonContains(resolveColumn(param), value);
}

final class _Callback extends Filter {
  _Callback(this.callback);

  final FilterCallback callback;

  @override
  FutureOr<void> apply(
    ModelQuery<Model> query,
    Object? value,
    String param,
    Request request,
  ) => callback(query, value, param, request);
}

final class _Scope extends Filter {
  _Scope(this.name);

  final String name;

  @override
  void apply(ModelQuery<Model> query, Object? value, String param, Request r) {
    if (query.definition.scopes.containsKey(name)) {
      query.scope(name, [r]);
    }
  }
}
