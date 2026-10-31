import '../request.dart';
import 'json_api_resource.dart';

/// `?fields[type]=a,b` and `?include=author,comments.user`, as Laravel's
/// `JsonApiRequest` reads them.
final class JsonApiRequest {
  JsonApiRequest._(this.request);

  /// One per request: every resource of a response reads the same query.
  factory JsonApiRequest.of(Request? request) => request == null
      ? JsonApiRequest._(null)
      : _cache[request] ??= JsonApiRequest._(request);

  static final Expando<JsonApiRequest> _cache = Expando<JsonApiRequest>();

  final Request? request;

  late final Map<String, List<String>> _fields = _parseFields();
  late final Map<String, List<String?>> _included = _parseIncluded();

  Map<String, List<String>> _parseFields() {
    final fields = request?.queryInput['fields'];
    if (fields is! Map<Object?, Object?>) {
      return const {};
    }
    return {
      for (final entry in fields.entries)
        '${entry.key}': switch (entry.value) {
          final String names when names.isNotEmpty => names.split(','),
          _ => const <String>[],
        },
    };
  }

  Map<String, List<String?>> _parseIncluded() {
    final included = <String, List<String?>>{};
    final include = request?.queryInput['include'];
    if (include is! String || include.isEmpty) {
      return included;
    }
    for (final item in include.split(',')) {
      final dot = item.indexOf('.');
      final relation = dot == -1 ? item : item.substring(0, dot);
      final nested = dot == -1 ? null : item.substring(dot + 1);
      included.putIfAbsent(relation, () => []).add(nested);
    }
    return included;
  }

  /// The attributes asked for on [type].
  List<String> sparseFields(String type) => _fields[type] ?? const [];

  /// Whether the query names [type], even with no attributes.
  bool hasSparseFieldset(String type) => _fields.containsKey(type);

  /// The relations asked for, or those under [relation], cut to
  /// [JsonApiResource.relationshipDepth].
  List<String> sparseIncluded([String? relation]) {
    if (relation == null) {
      return _included.keys.toList();
    }
    final keep = JsonApiResource.relationshipDepth - 1;
    return [
      for (final item in _included[relation] ?? const <String?>[])
        if (item != null && item.isNotEmpty && keep > 0)
          item.split('.').take(keep).join('.'),
    ];
  }
}
