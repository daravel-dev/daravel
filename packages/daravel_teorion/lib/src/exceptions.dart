import 'package:daravel/daravel.dart';

import 'query_filter.dart';

// laravel-teorion's exceptions, with its messages. Laravel answers them as
// 500 (RuntimeException); they come from the client's request, so Daravel
// answers 400.

final class DisallowedSortException extends HttpException {
  DisallowedSortException(String column)
    : super(400, 'Sort column [$column] is not in the allowed sorts list.');
}

final class DisallowedScopeException extends HttpException {
  DisallowedScopeException(String scope)
    : super(400, 'Scope [$scope] is not in the allowed scopes list.');
}

final class DisallowedWithException extends HttpException {
  DisallowedWithException(String relation)
    : super(400, 'Relation [$relation] is not in the allowed withs list.');
}

/// `?withs[]=author:id,password` asked for a column outside
/// [QueryFilter.allowedWithColumns] (a Daravel addition: laravel-teorion
/// passes any column through).
final class DisallowedWithColumnsException extends HttpException {
  DisallowedWithColumnsException(String relation, String column)
    : super(
        400,
        'Column [$column] of relation [$relation] is not in the allowed '
        'with columns list.',
      );
}

final class RequiredFilterMissingException extends HttpException {
  RequiredFilterMissingException(String param)
    : super(
        400,
        'Required filter parameter [$param] is missing from the request.',
      );
}

/// A whitelisted scope the model does not define (strict mode).
final class ScopeMethodNotFoundException extends DaravelException {
  ScopeMethodNotFoundException(String scope, String table)
    : super(
        'Scope [$scope] is whitelisted but [$table] defines no scope by that '
        'name.',
      );
}

/// No [QueryFilter] for a model.
final class QueryFilterNotFoundException extends DaravelException {
  QueryFilterNotFoundException(Type model)
    : super(
        'QueryFilter could not be resolved for model [$model]. Register it '
        '(withQueryFilters({$model: ${model}QueryFilter.new})), mix '
        'Filterable into the model, or pass one.',
      );
}
