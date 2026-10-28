/// The first-party packages `pub:list`, `pub:search` and `pub:add` know,
/// with what installing each one takes. Kept honest by
/// `test/package_registry_test.dart`, which checks every builder call,
/// `.env` key, migration and command list against the package's source.
library;

/// One first-party package and its installation.
final class PackageManifest {
  const PackageManifest({
    required this.package,
    required this.title,
    required this.category,
    required this.description,
    this.aliases = const [],
    this.registration = const [],
    this.migrations = const [],
    this.commands,
    this.env = const [],
    this.next = const [],
    this.delegate,
    this.dev = false,
  });

  /// The pub package (`daravel_permission`).
  final String package;
  final String title;
  final String category;
  final String description;

  /// Other names `pub:add` accepts, matched exactly (`rbac`, `roles`).
  final List<String> aliases;

  /// Calls added to the application builder in `bootstrap/app.dart`.
  final List<String> registration;

  /// Migration classes added to `bootstrap/migrations.dart`.
  final List<String> migrations;

  /// The command list added to `bootstrap/commands.dart`, from the
  /// package's `commands.dart` library (`permissionCommands`).
  final String? commands;

  /// `.env` lines documented in `.env.example`; secrets stay empty.
  final List<String> env;

  /// What to do after installing.
  final List<String> next;

  /// The dartisan command that installs this package instead
  /// (`['db:install', 'pgsql']`).
  final List<String>? delegate;

  /// A `dev_dependencies` package.
  final bool dev;

  /// The short name (`permission` for `daravel_permission`).
  String get id => package.startsWith('daravel_')
      ? package.substring('daravel_'.length)
      : package;

  String get import => "import 'package:$package/$package.dart';";

  /// Every name `pub:add` matches exactly, lower case.
  Iterable<String> get names => {id, package, ...aliases};
}

/// The first-party packages, in the order `pub:list` shows them.
const List<PackageManifest> officialPackages = [
  PackageManifest(
    package: 'daravel_sqlite',
    title: 'SQLite',
    category: 'Database',
    description: 'SQLite driver, bundled with the native build',
    aliases: ['sqlite'],
    delegate: ['db:install', 'sqlite'],
  ),
  PackageManifest(
    package: 'daravel_postgres',
    title: 'PostgreSQL',
    category: 'Database',
    description: 'PostgreSQL driver, pooled connections',
    aliases: ['postgres', 'postgresql', 'pgsql', 'pg'],
    delegate: ['db:install', 'pgsql'],
  ),
  PackageManifest(
    package: 'daravel_mysql',
    title: 'MySQL / MariaDB',
    category: 'Database',
    description: 'MySQL and MariaDB driver',
    aliases: ['mysql', 'mariadb'],
    delegate: ['db:install', 'mysql'],
  ),
  PackageManifest(
    package: 'daravel_redis',
    title: 'Redis / Valkey',
    category: 'Infrastructure',
    description:
        'Cache, locks, rate limits, queues and broadcasting across servers',
    aliases: ['redis', 'valkey', 'cluster'],
    delegate: ['redis:install'],
  ),
  PackageManifest(
    package: 'daravel_s3',
    title: 'S3 storage',
    category: 'Storage',
    description:
        'Storage disk on AWS S3, Cloudflare R2, MinIO and compatible stores',
    aliases: ['s3', 'storage', 'r2', 'minio', 'aws', 'bucket', 'cloud'],
    registration: ['.withS3()'],
    env: [
      'FILESYSTEM_DISK=s3',
      'AWS_ACCESS_KEY_ID=',
      'AWS_SECRET_ACCESS_KEY=',
      'AWS_DEFAULT_REGION=us-east-1',
      'AWS_BUCKET=',
      'AWS_ENDPOINT=',
      'AWS_USE_PATH_STYLE_ENDPOINT=false',
    ],
    next: [
      "Set the AWS_* keys in .env; AWS_ENDPOINT for R2 or MinIO.",
      "Storage.disk('s3').put('reports/a.pdf', bytes)",
    ],
  ),
  PackageManifest(
    package: 'daravel_permission',
    title: 'Roles and permissions',
    category: 'Security',
    description: "Roles and permissions on spatie/laravel-permission's tables",
    aliases: ['permission', 'permissions', 'roles', 'rbac', 'spatie'],
    registration: ['.withPermissions()'],
    migrations: ['CreatePermissionTables'],
    commands: 'permissionCommands',
    env: [
      'PERMISSION_GUARD=web',
      'PERMISSION_CACHE_TTL=5m',
      'PERMISSION_WILDCARD=false',
      'PERMISSION_SUPER_ADMIN_ROLE=',
    ],
    next: [
      'dartisan migrate',
      'Add `with AuthenticatableModel, HasRoles` to your User model.',
      "router.get('/admin', handler).middleware(['auth', 'role:admin'])",
    ],
  ),
  PackageManifest(
    package: 'daravel_activitylog',
    title: 'Activity log',
    category: 'Audit',
    description: "Model change history on spatie/laravel-activitylog's table",
    aliases: ['activitylog', 'activity', 'audit', 'history'],
    registration: ['.withActivityLog()'],
    migrations: ['CreateActivityLogTable'],
    commands: 'activitylogCommands',
    env: [
      'ACTIVITY_LOGGER_ENABLED=true',
      'ACTIVITY_LOGGER_DELETE_RECORDS_OLDER_THAN_DAYS=365',
    ],
    next: [
      'dartisan migrate',
      'Add `with LogsActivity` and `observers: [ActivityLogObserver<Post>()]` to a model.',
    ],
  ),
  PackageManifest(
    package: 'daravel_teorion',
    title: 'Query filters',
    category: 'API',
    description: 'Listings filtered, sorted and paged from the query string',
    aliases: ['teorion', 'filters', 'query-filters', 'filter'],
    next: [
      'dartisan make:query-filter Post',
      'Register the filters: .withQueryFilters({Post: PostQueryFilter.new})',
    ],
  ),
  PackageManifest(
    package: 'daravel_livekit',
    title: 'LiveKit',
    category: 'Media',
    description: 'LiveKit server SDK: access tokens, rooms, verified webhooks',
    aliases: ['livekit', 'webrtc', 'video', 'meeting', 'conference'],
    registration: ['.withLivekit()'],
    env: [
      'LIVEKIT_URL=http://127.0.0.1:7880',
      'LIVEKIT_API_KEY=',
      'LIVEKIT_API_SECRET=',
    ],
    next: [
      'Set LIVEKIT_API_KEY and LIVEKIT_API_SECRET in .env.',
      "Livekit.token(identity: user.uuid, video: VideoGrant(roomJoin: true, room: 'class-7a'))",
    ],
  ),
  PackageManifest(
    package: 'daravel_google',
    title: 'Google',
    category: 'Cloud',
    description:
        'Google Calendar with OAuth refresh and service accounts, Meet links',
    aliases: ['google', 'calendar', 'meet', 'workspace', 'cloud'],
    registration: ['.withGoogle()'],
    env: [
      'GOOGLE_CLIENT_ID=',
      'GOOGLE_CLIENT_SECRET=',
      'GOOGLE_REDIRECT_URI=',
      'GOOGLE_APPLICATION_CREDENTIALS=',
      'GOOGLE_CALENDAR_ID=',
    ],
    next: ['Set the GOOGLE_* keys in .env (OAuth, or a service account file).'],
  ),
  PackageManifest(
    package: 'daravel_teobiefy',
    title: 'Teobiefy',
    category: 'Security',
    description: 'Encrypted API payloads: X25519 handshake, ChaCha20-Poly1305',
    aliases: ['teobiefy', 'encryption', 'handshake', 'payload'],
    registration: ['.withTeobiefy()'],
    env: [
      'LIBSODIUM_SESSION_TTL=1800',
      'LIBSODIUM_PAYLOAD_V2_ENABLED=false',
      'LIBSODIUM_STRICT_PAYLOAD=false',
    ],
    next: [
      "router.post('/api/v1/session-key', Teobiefy.handshake)",
      "Protect routes with the `teobiefy` middleware.",
    ],
  ),
  PackageManifest(
    package: 'daravel_test',
    title: 'Testing toolkit',
    category: 'Development',
    description: 'TestClient, assertions, refreshDatabase, time travel',
    aliases: ['test', 'testing'],
    dev: true,
  ),
  PackageManifest(
    package: 'daravel_lints',
    title: 'Lints',
    category: 'Development',
    description: 'AST lint rules and registry checks (dartisan lint)',
    aliases: ['lints', 'lint'],
    dev: true,
  ),
];

/// The packages [query] names exactly: an id, a package name or an alias,
/// ignoring case. More than one when an alias is shared (`cloud`).
List<PackageManifest> resolvePackages(String query) {
  final wanted = query.trim().toLowerCase();
  return [
    for (final manifest in officialPackages)
      if (manifest.names.any((name) => name.toLowerCase() == wanted)) manifest,
  ];
}

/// The packages matching [query] best first: exact names, then names,
/// titles, categories and descriptions that contain it, then names one or
/// two edits away (a typo). For search and suggestions, never to install.
List<PackageManifest> searchPackages(String query) {
  final wanted = query.trim().toLowerCase();
  if (wanted.isEmpty) {
    return officialPackages;
  }
  final scored = <(PackageManifest, int)>[];
  for (final manifest in officialPackages) {
    final names = manifest.names.map((n) => n.toLowerCase()).toList();
    final text = [
      manifest.title,
      manifest.category,
      manifest.description,
    ].join(' ').toLowerCase();
    final int? score;
    if (names.contains(wanted)) {
      score = 0;
    } else if (names.any((n) => n.contains(wanted))) {
      score = 1;
    } else if (text.contains(wanted)) {
      score = 2;
    } else if (wanted.length >= 4 &&
        names.any(
          (n) => levenshtein(n, wanted) <= (wanted.length >= 7 ? 2 : 1),
        )) {
      score = 3;
    } else {
      score = null;
    }
    if (score != null) {
      scored.add((manifest, score));
    }
  }
  scored.sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (manifest, _) in scored) manifest];
}

/// The number of single-character edits between [a] and [b].
int levenshtein(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      current[j] = [
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    previous = current;
  }
  return previous[b.length];
}
