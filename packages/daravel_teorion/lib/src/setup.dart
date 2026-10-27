import 'package:daravel/daravel.dart';

import 'query_filter.dart';

/// `withQueryFilters()` on the application builder.
extension TeorionApplicationBuilder on ApplicationBuilder {
  /// Registers each model's query filter (laravel-teorion's convention,
  /// written out since Dart has no reflection), usually from
  /// `bootstrap/query_filters.dart`:
  ///
  /// ```dart
  /// .withQueryFilters({Post: PostQueryFilter.new, User: UserQueryFilter.new})
  /// ```
  ApplicationBuilder withQueryFilters(
    Map<Type, QueryFilter<Model> Function()> filters,
  ) => withConfig<TeorionConfig>(TeorionConfig.fromEnv).withBindings(
    (container) =>
        container.instance<QueryFilterRegistry>(QueryFilterRegistry(filters)),
  );
}
