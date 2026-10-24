import 'package:collection/collection.dart';
import 'package:test/test.dart';

/// Laravel 12 wire and storage contracts that Daravel locks (BLUEPRINT_V2
/// §11.2). Each value cites the Laravel / Sanctum source it was taken from
/// (laravel/framework `12.x`, laravel/sanctum `4.x`, laravel/laravel `12.x`),
/// so a change in either framework is traceable. Changing a value here is a
/// compatibility decision and needs an ADR.
abstract final class LaravelContract {
  // -- Errors (Foundation/Exceptions/Handler.php, non-debug) ---------------

  /// `AuthenticationException` default message (401).
  static const String unauthenticated = 'Unauthenticated.';

  /// `AuthorizationException` / `AccessDeniedHttpException` message (403).
  static const String unauthorized = 'This action is unauthorized.';

  /// `ThrottleRequests::buildException` message (429).
  static const String tooManyAttempts = 'Too Many Attempts.';

  /// `convertExceptionToArray()` for non-HTTP exceptions (500).
  static const String serverError = 'Server Error';

  /// `ValidatePostSize` message (413).
  static const String postTooLarge = 'The POST data is too large.';

  /// `ValidationException::summarize` with no messages.
  static const String invalidData = 'The given data was invalid.';

  /// `AbstractRouteCollection::handleMatchedRoute` (404).
  static String routeNotFound(String path) =>
      'The route $path could not be found.';

  /// `AbstractRouteCollection::requestMethodNotAllowed` (405).
  static String methodNotAllowed(
    String method,
    String path,
    List<String> allowed,
  ) =>
      'The $method method is not supported for route $path. '
      'Supported methods: ${allowed.join(', ')}.';

  /// `ModelNotFoundException::setModel` (404 after `prepareException`).
  static String modelNotFound(String model, [List<Object?> ids = const []]) =>
      'No query results for model [$model]'
      '${ids.isEmpty ? '.' : ' ${ids.join(', ')}'}';

  /// `ValidationException::summarize`: first message plus
  /// `(and N more error[s])`.
  static String validationSummary(List<String> messages) {
    if (messages.isEmpty) {
      return invalidData;
    }
    final more = messages.length - 1;
    if (more == 0) {
      return messages.first;
    }
    return '${messages.first} (and $more more ${more == 1 ? 'error' : 'errors'})';
  }

  /// `ThrottleRequests::getHeaders` on a 429.
  static const List<String> throttleHeaders = <String>[
    'x-ratelimit-limit',
    'x-ratelimit-remaining',
    'retry-after',
    'x-ratelimit-reset',
  ];

  // -- Pagination (Pagination/*.php, lang/en/pagination.php) --------------

  /// `LengthAwarePaginator::toArray()` key order.
  static const List<String> lengthAwarePaginatorKeys = <String>[
    'current_page',
    'data',
    'first_page_url',
    'from',
    'last_page',
    'last_page_url',
    'links',
    'next_page_url',
    'path',
    'per_page',
    'prev_page_url',
    'to',
    'total',
  ];

  /// `Paginator::toArray()` key order (`simplePaginate`).
  static const List<String> simplePaginatorKeys = <String>[
    'current_page',
    'current_page_url',
    'data',
    'first_page_url',
    'from',
    'next_page_url',
    'path',
    'per_page',
    'prev_page_url',
    'to',
  ];

  /// `CursorPaginator::toArray()` key order.
  static const List<String> cursorPaginatorKeys = <String>[
    'data',
    'path',
    'per_page',
    'next_cursor',
    'next_page_url',
    'prev_cursor',
    'prev_page_url',
  ];

  /// `pagination.previous` / `pagination.next`.
  static const String previousLabel = '&laquo; Previous';
  static const String nextLabel = 'Next &raquo;';

  /// Page labels of `LengthAwarePaginator::linkCollection()` between the
  /// previous/next links: a port of `UrlWindow` (`null` = `...`).
  static List<int?> urlWindow(int current, int last, {int onEachSide = 3}) {
    List<int> range(int from, int to) => [for (var p = from; p <= to; p++) p];
    if (last < onEachSide * 2 + 8) {
      return range(1, last);
    }
    final window = onEachSide + 4;
    if (current <= window) {
      return [...range(1, window + onEachSide), null, last - 1, last];
    }
    if (current > last - window) {
      return [1, 2, null, ...range(last - (window + onEachSide - 1), last)];
    }
    return [
      1,
      2,
      null,
      ...range(current - onEachSide, current + onEachSide),
      null,
      last - 1,
      last,
    ];
  }

  /// `PaginatedResourceResponse`: `links` keys, and `meta` = paginator array
  /// without `data` and the four URL keys.
  static const List<String> resourceLinksKeys = <String>[
    'first',
    'last',
    'prev',
    'next',
  ];
  static const Set<String> resourceMetaExcluded = <String>{
    'data',
    'first_page_url',
    'last_page_url',
    'prev_page_url',
    'next_page_url',
  };

  /// `Cursor::encode()` boolean key.
  static const String cursorDirectionKey = '_pointsToNextItems';

  // -- Auth (laravel/sanctum 4.x) -----------------------------------------

  /// `HasApiTokens::createToken` → `NewAccessToken`: `{id}|{prefix}{40
  /// random}{crc32b(random)}`; the table stores `sha256` of everything after
  /// the `|`.
  static final RegExp sanctumPlainTextToken = RegExp(
    r'^(\d+)\|([A-Za-z0-9_]*?)([A-Za-z0-9]{40})([0-9a-f]{8})$',
  );

  /// `bcrypt('password')` from Laravel's historic `UserFactory`
  /// (`$2y$10$`, cost 10).
  static const String bcryptOfPassword =
      r'$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi';

  /// Default morph class of a model (`tokenable_type`).
  static String morphClass(String model) => 'App\\Models\\$model';

  // -- Dates (Carbon::toJSON) ---------------------------------------------

  /// `2026-01-02T03:04:05.000000Z`: UTC with microseconds.
  static final RegExp jsonDate = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$',
  );

  // -- Schema (laravel/laravel 12.x migrations, DatabaseMigrationRepository,
  //    sanctum migration) -------------------------------------------------

  /// Columns (in order) and nullability of the tables Laravel and Daravel
  /// share. `true` = nullable.
  static const Map<String, Map<String, bool>> sharedTables = {
    'migrations': {'id': false, 'migration': false, 'batch': false},
    'users': {
      'id': false,
      'name': false,
      'email': false,
      'email_verified_at': true,
      'password': false,
      'remember_token': true,
      'created_at': true,
      'updated_at': true,
    },
    'cache': {'key': false, 'value': false, 'expiration': false},
    'cache_locks': {'key': false, 'owner': false, 'expiration': false},
    'jobs': {
      'id': false,
      'queue': false,
      'payload': false,
      'attempts': false,
      'reserved_at': true,
      'available_at': false,
      'created_at': false,
    },
    'job_batches': {
      'id': false,
      'name': false,
      'total_jobs': false,
      'pending_jobs': false,
      'failed_jobs': false,
      'failed_job_ids': false,
      'options': true,
      'cancelled_at': true,
      'created_at': false,
      'finished_at': true,
    },
    'failed_jobs': {
      'id': false,
      'uuid': false,
      'connection': false,
      'queue': false,
      'payload': false,
      'exception': false,
      'failed_at': false,
    },
    'personal_access_tokens': {
      'id': false,
      'tokenable_type': false,
      'tokenable_id': false,
      'name': false,
      'token': false,
      'abilities': true,
      'last_used_at': true,
      'expires_at': true,
      'created_at': true,
      'updated_at': true,
    },
  };

  /// Migration names Laravel records in `migrations.migration`.
  static const Map<String, String> sharedMigrationNames = {
    'cache': '0001_01_01_000001_create_cache_table',
    'jobs': '0001_01_01_000002_create_jobs_table',
    'personal_access_tokens':
        '2019_12_14_000001_create_personal_access_tokens_table',
  };

  /// Indexed columns (single-column indexes or unique constraints) Laravel
  /// creates on the shared tables.
  static const Map<String, List<String>> sharedIndexes = {
    'cache': ['expiration'],
    'cache_locks': ['expiration'],
    'jobs': ['queue'],
    'failed_jobs': ['uuid'],
    'personal_access_tokens': ['token', 'expires_at'],
  };

  // -- Resource routes (Routing/ResourceRegistrar.php) ---------------------

  /// `Route::apiResource('photos', ...)`: method, URI, name.
  static List<(String, String, String)> apiResource(
    String name,
    String parameter,
  ) => [
    ('GET', name, '$name.index'),
    ('POST', name, '$name.store'),
    ('GET', '$name/{$parameter}', '$name.show'),
    ('PUT', '$name/{$parameter}', '$name.update'),
    ('PATCH', '$name/{$parameter}', '$name.update'),
    ('DELETE', '$name/{$parameter}', '$name.destroy'),
  ];
}

/// Matches a Laravel 422 body: exactly `{message, errors}`, the message
/// being the [LaravelContract.validationSummary] of the errors, and (when
/// given) the exact [errors].
Matcher isLaravelValidationError([Map<String, List<String>>? errors]) =>
    predicate<Object?>((body) {
      if (body is! Map<String, Object?>) {
        return false;
      }
      final actual = body['errors'];
      if (body.keys.toList().join(',') != 'message,errors' ||
          actual is! Map<String, Object?>) {
        return false;
      }
      final all = <String>[
        for (final list in actual.values) ...(list! as List<Object?>).cast(),
      ];
      if (body['message'] != LaravelContract.validationSummary(all)) {
        return false;
      }
      return errors == null ||
          const DeepCollectionEquality().equals(actual, errors);
    }, 'a Laravel validation error body');

/// Matches `{"message": message}` and nothing else.
Matcher isLaravelErrorBody(String message) =>
    equals(<String, Object?>{'message': message});

/// Matches a `paginate()` body: Laravel key order, `links` shape with the
/// `UrlWindow` page labels, and consistent `from`/`to`/`last_page`.
Matcher isLaravelLengthAwarePaginator() => predicate<Object?>((body) {
  if (body is! Map<String, Object?>) {
    return false;
  }
  if (!const ListEquality<String>().equals(
    body.keys.toList(),
    LaravelContract.lengthAwarePaginatorKeys,
  )) {
    return false;
  }
  return _linksMatch(
    body['links'],
    body['current_page']! as int,
    body['last_page']! as int,
  );
}, 'a Laravel LengthAwarePaginator body');

bool _linksMatch(Object? links, int current, int last) {
  if (links is! List<Object?> || links.length < 2) {
    return false;
  }
  final first = links.first! as Map<String, Object?>;
  final lastLink = links.last! as Map<String, Object?>;
  if (first['label'] != LaravelContract.previousLabel ||
      lastLink['label'] != LaravelContract.nextLabel ||
      first['page'] != (current > 1 ? current - 1 : null) ||
      lastLink['page'] != (current < last ? current + 1 : null)) {
    return false;
  }
  final labels = [
    for (final link in links.sublist(1, links.length - 1))
      (link! as Map<String, Object?>)['label'],
  ];
  final expected = [
    for (final page in LaravelContract.urlWindow(current, last))
      page == null ? '...' : '$page',
  ];
  return const ListEquality<Object?>().equals(labels, expected);
}

/// Matches a paginated `JsonResource::collection` body:
/// `{data, links: {first, last, prev, next}, meta}` with `meta` equal to the
/// paginator array minus `data` and the URL keys.
Matcher isLaravelPaginatedResource(Map<String, Object?> paginatorJson) =>
    predicate<Object?>((body) {
      if (body is! Map<String, Object?>) {
        return false;
      }
      final links = body['links'];
      final meta = body['meta'];
      if (links is! Map<String, Object?> || meta is! Map<String, Object?>) {
        return false;
      }
      final expectedMeta = <String, Object?>{
        for (final entry in paginatorJson.entries)
          if (!LaravelContract.resourceMetaExcluded.contains(entry.key))
            entry.key: entry.value,
      };
      return const ListEquality<String>().equals(
            links.keys.toList(),
            LaravelContract.resourceLinksKeys,
          ) &&
          links['first'] == paginatorJson['first_page_url'] &&
          links['last'] == paginatorJson['last_page_url'] &&
          links['prev'] == paginatorJson['prev_page_url'] &&
          links['next'] == paginatorJson['next_page_url'] &&
          const ListEquality<String>().equals(
            meta.keys.toList(),
            expectedMeta.keys.toList(),
          );
    }, 'a Laravel paginated resource body');
