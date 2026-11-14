import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import '../dartisan_cli.dart';
import 'guide_pages.g.dart';

/// MCP protocol versions this server speaks, newest first.
const List<String> mcpProtocolVersions = [
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

/// Commands `run_command` offers an agent, by their canonical name: reading
/// the project, writing its code (every `make:*` command too), checks, and
/// `migrate` (without `--seed` in production). Any other command is refused
/// unless `mcp:serve --allow-command=<name>` opens it.
///
/// Options that would take an offered command outside the project are
/// refused: `route:diff --laravel` (runs `php` in another directory),
/// `security:audit --target` (it audits `APP_URL`), and an `--output` of
/// `openapi:generate` or `security:audit`, or `route:diff --laravel-json`,
/// outside the project directory.
const Set<String> mcpOfferedCommands = {
  'about',
  'doctor',
  'list',
  'help',
  'route:list',
  'route:diff',
  'model:show',
  'db:show',
  'db:table',
  'migrate:status',
  'schedule:list',
  'queue:failed',
  'security:audit',
  'model:sync',
  'request:sync',
  'names:sync',
  'openapi:generate',
  'stub:publish',
  'lint',
  'migrate',
};

/// Commands `run_command` offers an agent outside production only. `test`
/// is one: the project's tests run with the database their setup picks,
/// which on a production machine is production's.
const Set<String> mcpOfferedOutsideProduction = {
  'test',
  'migrate:fresh',
  'migrate:reset',
  'migrate:rollback',
  'db:seed',
  'cache:clear',
  'storage:link',
  'queue:retry',
  'queue:forget',
};

/// Commands `--allow-command` cannot open: they run until stopped or read
/// a terminal.
const Set<String> mcpNeverOffered = {
  'serve',
  'mcp:serve',
  'tinker',
  'queue:work',
  'schedule:work',
};

/// Commands `--allow-command` cannot open while `APP_ENV=production`:
/// they change data or the deployment, which stays a terminal's job.
const Set<String> mcpProductionOnlyInTerminal = {
  ...mcpOfferedOutsideProduction,
  'db:restore',
  'db:transfer',
  'db:replicate',
  'queue:flush',
  'queue:clear',
  'key:generate',
  'env:decrypt',
  'env:encrypt',
  'down',
  'up',
};

/// Commands `run_command` never starts: long-running or interactive.
@Deprecated(
  'run_command offers mcpOfferedCommands (and mcpOfferedOutsideProduction '
  'outside production) and refuses any other command; see mcpNeverOffered.',
)
const Set<String> mcpRefusedCommands = mcpNeverOffered;

/// Commands `run_command` refuses when `APP_ENV=production`.
@Deprecated(
  'run_command offers mcpOfferedCommands (and mcpOfferedOutsideProduction '
  'outside production) and refuses any other command; see '
  'mcpProductionOnlyInTerminal.',
)
const Set<String> mcpProductionRefused = {
  'migrate:fresh',
  'migrate:reset',
  'migrate:rollback',
  'db:seed',
  'queue:flush',
  'queue:clear',
  'key:generate',
  'env:decrypt',
  // Maintenance mode from an agent, and env:encrypt --prune deletes .env.
  'down',
  'env:encrypt',
};

/// Runs a dartisan command for `run_command`: exit code and output.
typedef McpCommandRunner =
    Future<({int exitCode, String stdout, String stderr})> Function(
      String command,
      List<String> arguments,
    );

/// A tool a package adds to `mcp:serve` (daravel_redis's `redis_inspect`),
/// offered by one of its commands ([McpToolSource]).
final class McpTool {
  /// A tool the MCP server offers an assistant.
  const McpTool({
    required this.name,
    required this.description,
    required this.run,
    this.properties = const {},
    this.required = const [],
    this.readOnly = true,
  });

  /// The tool's name.
  final String name;

  /// What the tool does, for the assistant.
  final String description;

  /// The input schema's properties (`{'key': {'type': 'string'}}`).
  final Map<String, Object?> properties;

  /// The arguments it requires.
  final List<String> required;

  /// Tools that change something are offered with `--allow-write` only.
  final bool readOnly;

  /// Answers a call, inside the application's scope; a string, or a value
  /// sent as JSON.
  final Future<Object?> Function(Map<String, Object?> arguments) run;
}

/// A command that brings MCP tools: `mcp:serve` offers the tools of every
/// registered command that is one, so a package adds tools through the
/// commands it already registers in `bootstrap/commands.dart`.
abstract interface class McpToolSource {
  /// The tools offered.
  List<McpTool> get mcpTools;
}

/// The tools of [runner]'s commands that are [McpToolSource]s.
List<McpTool> mcpToolsOf(CommandRunner<int>? runner) => [
  for (final command in {...?runner?.commands.values})
    if (command case final McpToolSource source) ...source.mcpTools,
];

/// A Model Context Protocol server (JSON-RPC 2.0) that gives AI coding
/// agents the project's routes, database schema, conventions and guide.
///
/// Read-only unless [allowWrite]; then `run_command` runs the dartisan
/// commands in [mcpOfferedCommands] (and [mcpOfferedOutsideProduction]
/// outside production) and those [allowedCommands] opens. It needs the
/// [runner] the command runs with: the command is read with that runner's
/// own parser before anything is decided, so global flags in front, `--`
/// and aliases name the command that would really run. Without a runner,
/// `run_command` refuses every command.
final class McpServer {
  /// An MCP server over stdin and stdout for an AI assistant.
  McpServer(
    this.app, {
    this.allowWrite = false,
    McpCommandRunner? runCommand,
    this.tools = const [],
    this.runner,
    Set<String> allowedCommands = const {},
  }) : _runCommand = runCommand ?? _spawnDartisan,
       allowedCommands = Set.unmodifiable(allowedCommands);

  /// The runner `run_command`'s commands run with (the project's
  /// `bin/dartisan.dart`).
  final CommandRunner<int>? runner;

  /// Commands the user opened beyond [mcpOfferedCommands]
  /// (`mcp:serve --allow-command`); never [mcpNeverOffered], and never
  /// [mcpProductionOnlyInTerminal] in production.
  final Set<String> allowedCommands;

  /// Tools packages add ([McpToolSource]).
  final List<McpTool> tools;

  Iterable<McpTool> get _extra =>
      tools.where((tool) => tool.readOnly || allowWrite);

  /// A booted application.
  final Application app;

  /// Whether tools that change the project are offered.
  final bool allowWrite;
  final McpCommandRunner _runCommand;

  /// Handles one JSON-RPC message; `null` for notifications.
  Future<Map<String, Object?>?> handle(Object? message) async {
    if (message is! Map<String, Object?>) {
      return _error(null, -32600, 'Invalid Request');
    }
    final id = message['id'];
    final method = message['method'];
    if (method is! String) {
      return id == null ? null : _error(id, -32600, 'Invalid Request');
    }
    if (!message.containsKey('id')) {
      // Notifications (`notifications/initialized`, cancellations) need no
      // answer.
      return null;
    }
    final params = message['params'] is Map<String, Object?>
        ? message['params']! as Map<String, Object?>
        : const <String, Object?>{};
    switch (method) {
      case 'initialize':
        final requested = params['protocolVersion'];
        return _result(id, {
          'protocolVersion': mcpProtocolVersions.contains(requested)
              ? requested
              : mcpProtocolVersions.first,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'dartisan', 'version': daravelVersion},
          'instructions': _instructions,
        });
      case 'ping':
        return _result(id, const <String, Object?>{});
      case 'tools/list':
        return _result(id, {'tools': _tools()});
      case 'tools/call':
        final name = params['name'];
        final arguments = params['arguments'] is Map<String, Object?>
            ? params['arguments']! as Map<String, Object?>
            : const <String, Object?>{};
        if (name is! String || !_tools().any((t) => t['name'] == name)) {
          return _error(id, -32602, 'Unknown tool: $name');
        }
        try {
          final value = await app.run(() => _call(name, arguments));
          return _result(id, {
            'content': [
              {
                'type': 'text',
                'text': value is String
                    ? value
                    : const JsonEncoder.withIndent('  ').convert(value),
              },
            ],
            'isError': false,
          });
        } on Object catch (error) {
          return _result(id, {
            'content': [
              {'type': 'text', 'text': '$error'},
            ],
            'isError': true,
          });
        }
      default:
        return _error(id, -32601, 'Method not found: $method');
    }
  }

  /// Serves newline-delimited JSON-RPC from [input] to [output] (the MCP
  /// stdio transport) until [input] closes.
  Future<void> serve(Stream<List<int>> input, IOSink output) async {
    final lines = input.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }
      Map<String, Object?>? response;
      try {
        response = await handle(jsonDecode(line));
      } on FormatException {
        response = _error(null, -32700, 'Parse error');
      }
      if (response != null) {
        output.writeln(jsonEncode(response));
        await output.flush();
      }
    }
  }

  List<Map<String, Object?>> _tools() => [
    _tool(
      'about',
      'Daravel version, environment and the configured drivers.',
      const {},
    ),
    _tool(
      'routes',
      'The registered routes: methods, URI, name, controller action, '
          'middleware, validation rules (and their JSON Schema) and the '
          'documented response.',
      const {
        'path': {'type': 'string', 'description': 'URI contains this.'},
        'method': {'type': 'string', 'description': 'GET, POST, ...'},
      },
    ),
    _tool(
      'schema',
      'Database tables with column and row counts; with "table", that '
          "table's columns (type, nullable, default, key).",
      const {
        'table': {'type': 'string', 'description': 'One table to describe.'},
      },
    ),
    _tool(
      'models',
      'The models in bootstrap/models.dart with their tables and relations; '
          'with "model", its attributes (columns with type, cast, fillable, '
          'hidden), keys and relations (type, related model, foreign keys).',
      const {
        'model': {
          'type': 'string',
          'description': 'Class name (Post), morph class or table.',
        },
      },
    ),
    _tool(
      'db_query',
      'Runs one read-only SELECT, WITH or EXPLAIN statement on the default '
          'connection (in a read-only transaction, always rolled back, '
          'stopped after 10 seconds) and returns at most "limit" rows.',
      const {
        'sql': {'type': 'string', 'description': 'Use ? for bindings.'},
        'bindings': {'type': 'array', 'description': 'Values for the ?s.'},
        'limit': {'type': 'integer', 'description': 'Rows (default 100).'},
      },
      required: const ['sql'],
    ),
    _tool(
      'read_logs',
      'The newest records of the daily log files (LOG_STACK must include '
          '"daily"), oldest first.',
      const {
        'count': {'type': 'integer', 'description': 'Records (default 20).'},
        'level': {
          'type': 'string',
          'description': 'Minimum level: debug, info, warning, error, ...',
        },
      },
    ),
    _tool(
      'last_error',
      'The newest error-level log record (message, exception, stack trace).',
      const {},
    ),
    _tool(
      'conventions',
      'How a Daravel project is organised: explicit registries, '
          'generators, the model pattern, time, Laravel-compatible formats '
          'and lint rules. Read it before writing code.',
      const {},
    ),
    _tool(
      'docs_search',
      'Searches the Daravel guide of the installed version; returns the '
          'best matching sections.',
      const {
        'query': {'type': 'string', 'description': 'Words to look for.'},
        'limit': {'type': 'integer', 'description': 'Sections (default 5).'},
        'locale': {
          'type': 'string',
          'enum': ['en', 'id'],
          'description': 'id also searches the Indonesian pages (default en).',
        },
      },
      required: const ['query'],
    ),
    if (allowWrite)
      _tool(
        'run_command',
        'Runs a dartisan command in the project and returns its output. '
            'Offered: ${_offered.join(', ')}. Any other command is refused '
            '(migrate --seed too, in production).',
        const {
          'command': {'type': 'string', 'description': 'e.g. make:model'},
          'arguments': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'e.g. ["Post", "--migration"]',
          },
        },
        required: const ['command'],
        readOnly: false,
      ),
    for (final tool in _extra)
      _tool(
        tool.name,
        tool.description,
        tool.properties,
        required: tool.required,
        readOnly: tool.readOnly,
      ),
  ];

  static Map<String, Object?> _tool(
    String name,
    String description,
    Map<String, Object?> properties, {
    List<String> required = const [],
    bool readOnly = true,
  }) => {
    'name': name,
    'description': description,
    'inputSchema': {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    },
    'annotations': {'readOnlyHint': readOnly},
  };

  Future<Object?> _call(String name, Map<String, Object?> args) async {
    switch (name) {
      case 'about':
        final config = app.config.section<DatabaseConfig>();
        final appConfig = app.config.section<AppConfig>();
        return {
          'daravel': daravelVersion,
          'dart': Platform.version.split(' ').first,
          'app': {'name': appConfig.name, 'env': appConfig.env},
          'database': {
            'default': config.defaultConnection,
            'driver': config.connections[config.defaultConnection]?.driver,
          },
          'queue': app.env.string('QUEUE_CONNECTION', 'sync'),
          'cache': app.env.string('CACHE_STORE', 'memory'),
          'routes': app.router.routes.length,
        };
      case 'routes':
        final path = args['path'] as String?;
        final method = (args['method'] as String?)?.toUpperCase();
        return [
          for (final route in app.router.routes)
            if ((path == null || route.path.contains(path)) &&
                (method == null || route.methods.contains(method)))
              _route(route),
        ];
      case 'schema':
        final table = args['table'] as String?;
        final rows = table == null
            ? await describeDatabase(DB.manager)
            : await describeTable(DB.manager, table);
        if (rows == null) {
          throw StateError('Table [$table] does not exist.');
        }
        final header = rows.first;
        return [
          for (final row in rows.skip(1))
            {
              for (var i = 0; i < header.length; i++)
                header[i].toLowerCase(): row[i],
            },
        ];
      case 'models':
        final registry = app.container.make<ModelRegistry>();
        final wanted = args['model'] as String?;
        if (wanted == null) {
          if (registry.models.isEmpty) {
            return 'No models are registered. List them in '
                'bootstrap/models.dart and pass it to withModels(...).';
          }
          return [
            for (final model in registry.models)
              {
                'class': modelClassName(model),
                'table': model.table,
                'relations': {
                  for (final name in model.relationNames)
                    name: describeRelation(model.requireRelation(name))['type'],
                },
              },
          ];
        }
        final model = registry.find(wanted);
        if (model == null) {
          throw StateError('Model [$wanted] is not registered.');
        }
        return modelDetails(DB.manager, model);
      case 'db_query':
        final sql = args['sql'];
        if (sql is! String || sql.trim().isEmpty) {
          throw ArgumentError('Pass the SQL.');
        }
        final limit = args['limit'] is int
            ? (args['limit']! as int).clamp(1, 1000)
            : 100;
        final result = await readOnlySelect(
          DB.manager,
          sql,
          bindings: args['bindings'] as List<Object?>? ?? const [],
          limit: limit,
        );
        return {'rows': result.rows, 'truncated': result.truncated};
      case 'read_logs' || 'last_error':
        final config = app.config.section<LoggingConfig>();
        final directory = p.isAbsolute(config.path)
            ? config.path
            : p.join(app.basePath, config.path);
        final last = name == 'last_error';
        final level = args['level'] as String?;
        final records = readLogRecords(
          directory,
          count: last
              ? 1
              : args['count'] is int
              ? (args['count']! as int).clamp(1, 500)
              : 20,
          minLevel: last
              ? LogLevel.error
              : level == null
              ? null
              : LogLevel.parse(level),
        );
        if (records.isEmpty) {
          return last
              ? 'No error is logged in $directory.'
              : 'No log records in $directory (LOG_STACK needs "daily" '
                    'for log files).';
        }
        return last ? records.single : records;
      case 'conventions':
        return daravelConventions;
      case 'docs_search':
        final query = args['query'];
        if (query is! String || query.trim().isEmpty) {
          throw ArgumentError('Pass a query.');
        }
        final limit = args['limit'] is int ? args['limit']! as int : 5;
        return searchGuide(
          query,
          limit: limit,
          locale: args['locale'] == 'id' ? 'id' : 'en',
        );
      case 'run_command':
        final command = args['command'];
        if (command is! String || command.isEmpty) {
          throw ArgumentError('Pass a command.');
        }
        final arguments = [
          for (final value in args['arguments'] as List<Object?>? ?? const [])
            '$value',
        ];
        _checkCommand(command, arguments);
        final result = await _runCommand(command, arguments);
        return {
          'exitCode': result.exitCode,
          'stdout': _truncate(result.stdout),
          'stderr': _truncate(result.stderr),
        };
    }
    for (final tool in _extra) {
      if (tool.name == name) {
        return tool.run(args);
      }
    }
    throw StateError('Unknown tool: $name');
  }

  static Map<String, Object?> _route(RouteEntry route) {
    final rules = route.documentedRules();
    final response = route.declaredResponse;
    return {
      'methods': route.methods,
      'uri': route.path,
      'name': route.routeName,
      'action': route.actionName,
      'middleware': [
        for (final m in route.middlewareEntries)
          m is String ? m : m.runtimeType.toString(),
      ],
      if (route.parameterNames.isNotEmpty) 'parameters': route.parameterNames,
      if (route.formRequest != null)
        'formRequest': route.formRequest.runtimeType.toString(),
      if (rules != null) ...{
        'rules': {
          for (final MapEntry(:key, :value) in rules.entries)
            key: describeRules(value),
        },
        'requestSchema': rulesToJsonSchema(rules),
      },
      if (response != null)
        'response': {
          'name': response.name,
          'shape': response.shape.name,
          'status': response.status,
          'schema': response.schema,
        },
      if (route.summaryText != null) 'summary': route.summaryText,
      if (route.tagList.isNotEmpty) 'tags': route.tagList,
    };
  }

  bool get _production => app.config.section<AppConfig>().isProduction;

  /// Whether `run_command` offers the command named [name] (canonical).
  bool _offers(String name) {
    if (mcpNeverOffered.contains(name)) {
      return false;
    }
    if (_production && mcpProductionOnlyInTerminal.contains(name)) {
      return false;
    }
    return mcpOfferedCommands.contains(name) ||
        name.startsWith('make:') ||
        mcpOfferedOutsideProduction.contains(name) ||
        allowedCommands.contains(name);
  }

  /// The commands `run_command` offers here, for its description.
  List<String> get _offered => [
    for (final name in [
      ...mcpOfferedCommands,
      'make:*',
      ...mcpOfferedOutsideProduction,
      ...allowedCommands,
    ])
      if (name == 'make:*' || _offers(name)) name,
  ];

  /// Refuses [command] with [arguments] unless the runner's own parser
  /// reads them as a command `run_command` offers.
  void _checkCommand(String command, List<String> arguments) {
    final runner = this.runner;
    if (runner == null) {
      throw StateError(
        'run_command needs the dartisan runner; start the server with '
        'dartisan mcp:serve --allow-write.',
      );
    }
    if (command.startsWith('-')) {
      throw ArgumentError(
        'Pass the command name in command and its options in arguments.',
      );
    }
    final ArgResults parsed;
    try {
      parsed = runner.argParser.parse([command, ...arguments]);
    } on FormatException catch (error) {
      throw ArgumentError(
        'dartisan cannot read this command: ${error.message}',
      );
    }
    final named = parsed.command;
    final resolved = named == null ? null : runner.commands[named.name];
    if (named == null || resolved == null) {
      throw ArgumentError('dartisan reads no command here.');
    }
    final name = resolved.name;
    if (!_offers(name)) {
      throw StateError(
        mcpNeverOffered.contains(name)
            ? '$name runs until stopped; start it in a terminal instead.'
            : _production && mcpProductionOnlyInTerminal.contains(name)
            ? '$name is refused when APP_ENV=production; run it in a '
                  'terminal.'
            : '$name is not offered to agents; run it in a terminal, or '
                  'start the server with --allow-command=$name.',
      );
    }
    // migrate --seed is db:seed by another name.
    if (name == 'migrate' &&
        _production &&
        named.options.contains('seed') &&
        named['seed'] == true) {
      throw StateError(
        'migrate --seed is refused when APP_ENV=production; run it in a '
        'terminal.',
      );
    }
    _checkOptions(name, named);
  }

  /// Options of offered commands that name a path, kept inside the project.
  static const Map<String, List<String>> _pathOptions = {
    'openapi:generate': ['output'],
    'security:audit': ['output'],
    'route:diff': ['laravel-json'],
  };

  /// Refuses options that would take the offered command [name] outside
  /// the project: another program, another server, a path elsewhere.
  void _checkOptions(String name, ArgResults options) {
    String? given(String option) =>
        options.options.contains(option) ? options[option] as String? : null;
    final refusal = switch (name) {
      'route:diff' when given('laravel') != null =>
        '--laravel runs php in another directory; pass --laravel-json',
      'security:audit' when given('target') != null =>
        '--target audits another server; run_command audits APP_URL',
      _ => null,
    };
    if (refusal != null) {
      throw StateError('$name: $refusal.');
    }
    final root = p.normalize(p.absolute(app.basePath));
    for (final option in _pathOptions[name] ?? const <String>[]) {
      final value = given(option);
      if (value == null) {
        continue;
      }
      final path = p.normalize(p.absolute(p.join(root, value)));
      if (!p.isWithin(root, path)) {
        throw StateError(
          '$name: --$option must name a path inside the project.',
        );
      }
    }
  }

  static String _truncate(String text, [int max = 20000]) =>
      text.length <= max ? text : '${text.substring(0, max)}\n[truncated]';

  static Map<String, Object?> _result(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  static const String _instructions =
      'Context for a Daravel (Laravel-style Dart) project. Call '
      '"conventions" before writing code, "routes" and "schema" for the '
      'application as it is, and "docs_search" for framework APIs.';

  static Future<({int exitCode, String stdout, String stderr})> _spawnDartisan(
    String command,
    List<String> arguments,
  ) async {
    final result = await Process.run(dartExecutable(), [
      'run',
      'bin/dartisan.dart',
      command,
      ...arguments,
    ], workingDirectory: ProjectPaths.locate().root);
    return (
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }
}

/// Runs one `SELECT`/`WITH`/`EXPLAIN` statement that cannot write: inside a
/// transaction that is always rolled back and that the database keeps
/// read-only (SQLite `query_only`, PostgreSQL `SET TRANSACTION READ ONLY`,
/// MySQL and MariaDB `START TRANSACTION READ ONLY`, which also refuses
/// `FOR UPDATE` and `NEXTVAL`). At most [limit] rows, stopped after
/// [timeout] where the database can (`statement_timeout` on PostgreSQL,
/// `MAX_EXECUTION_TIME` on MySQL, `max_statement_time` on MariaDB).
///
/// On MySQL and MariaDB a statement calling `GET_LOCK` is refused: a named
/// lock belongs to the connection and outlives the rollback. Only a database
/// user that may read and nothing else guarantees a read; point the
/// connection `mcp:serve` uses at one where the database is shared.
Future<({List<Map<String, Object?>> rows, bool truncated})> readOnlySelect(
  DatabaseManager db,
  String sql, {
  List<Object?> bindings = const [],
  int limit = 100,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final statement = sql.trim().replaceFirst(RegExp(r';\s*$'), '');
  if (statement.contains(';')) {
    throw ArgumentError('Pass a single statement.');
  }
  final verb = RegExp(
    r'^(select|with|explain)\b',
    caseSensitive: false,
  ).firstMatch(statement)?.group(1)?.toLowerCase();
  if (verb == null) {
    throw ArgumentError('Only SELECT, WITH and EXPLAIN statements run.');
  }
  final dialect = db.dialectOf();
  if (dialect.isMySqlFamily &&
      RegExp(r'\bget_lock\s*\(', caseSensitive: false).hasMatch(statement)) {
    throw ArgumentError(
      'GET_LOCK does not run: a named lock outlives the rollback.',
    );
  }
  final explain = verb == 'explain';
  final milliseconds = timeout.inMilliseconds;
  // Ask for one row more than the limit to know whether rows were left out.
  final selected = explain
      ? statement
      : 'SELECT${dialect == SqlDialect.mysql ? ' /*+ MAX_EXECUTION_TIME($milliseconds) */' : ''} '
            '* FROM ($statement) daravel_mcp_query LIMIT ${limit + 1}';
  final query = dialect == SqlDialect.mariadb
      ? 'SET STATEMENT max_statement_time = ${milliseconds / 1000} FOR $selected'
      : selected;
  late List<Map<String, Object?>> rows;
  try {
    await db.transaction(() async {
      switch (dialect) {
        case SqlDialect.postgres:
          await db.statement('SET TRANSACTION READ ONLY');
          await db.statement('SET LOCAL statement_timeout = $milliseconds');
        case SqlDialect.sqlite:
          await db.statement('PRAGMA query_only = ON');
        case SqlDialect.mysql || SqlDialect.mariadb:
          // A transaction is read-only from its start: this one ends the
          // empty transaction the callback runs in and opens a read-only
          // one on the same connection, which the rollback then ends.
          await db.statement('START TRANSACTION READ ONLY');
      }
      try {
        rows = await db.select(query, bindings);
      } finally {
        if (dialect == SqlDialect.sqlite) {
          await db.statement('PRAGMA query_only = OFF');
        }
      }
      throw const _Rollback();
    });
  } on _Rollback {
    // Always rolled back.
  }
  return (
    rows: rows.length > limit ? rows.sublist(0, limit) : rows,
    truncated: rows.length > limit,
  );
}

final class _Rollback implements Exception {
  const _Rollback();
}

/// The newest [count] records of the daily log files in [directory]
/// (`LOG_STACK` with `daily`), newest last; [minLevel] filters by severity.
List<Map<String, Object?>> readLogRecords(
  String directory, {
  int count = 20,
  LogLevel? minLevel,
}) {
  final dir = Directory(directory);
  if (!dir.existsSync()) {
    return const [];
  }
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
  final records = <Map<String, Object?>>[];
  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (final line in lines.reversed) {
      if (records.length == count) {
        return records.reversed.toList();
      }
      final Object? record;
      try {
        record = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (record is! Map<String, Object?>) {
        continue;
      }
      if (minLevel != null) {
        final level = LogLevel.values.asNameMap()[record['level']];
        // LogLevel runs from debug up to emergency.
        if (level == null || level.index < minLevel.index) {
          continue;
        }
      }
      records.add(record);
    }
  }
  return records.reversed.toList();
}

/// A rule value (`'required|email'`, a list, a [Rule], a [RuleBuilder]) as
/// strings in the rule DSL.
List<String> describeRules(Object value) => switch (value) {
  final String text => [
    for (final part in text.split('|'))
      if (part.isNotEmpty) part,
  ],
  final RuleBuilder builder => [for (final r in builder.toList()) _rule(r)],
  final Rule rule => [_rule(rule)],
  final Iterable<Object?> list => [
    for (final item in list)
      if (item != null) ...describeRules(item),
  ],
  _ => ['$value'],
};

String _rule(Rule rule) => rule.parameters.isEmpty
    ? rule.name
    : '${rule.name}:${rule.parameters.values.join(',')}';

/// The best sections of the guide for [query]: headings count three times,
/// every query word must appear. [locale] `id` adds the Indonesian pages.
List<Map<String, Object?>> searchGuide(
  String query, {
  int limit = 5,
  String locale = 'en',
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9_:.]+'))
      .where((w) => w.length > 1)
      .toSet();
  if (words.isEmpty) {
    return const [];
  }
  final hits = <({String page, String heading, String text, int score})>[];
  for (final MapEntry(key: page, value: content) in guidePages.entries) {
    if (page.startsWith('id/') && locale != 'id') {
      continue;
    }
    var heading = page;
    final buffer = StringBuffer();
    void flush() {
      final text = buffer.toString().trim();
      buffer.clear();
      if (text.isEmpty) {
        return;
      }
      final body = text.toLowerCase();
      final title = heading.toLowerCase();
      var score = 0;
      for (final word in words) {
        final inBody = word.allMatches(body).length;
        final inTitle = word.allMatches(title).length;
        if (inBody + inTitle == 0) {
          return;
        }
        score += inBody + 3 * inTitle;
      }
      hits.add((page: page, heading: heading, text: text, score: score));
    }

    var inCode = false;
    for (final line in const LineSplitter().convert(content)) {
      if (line.startsWith('```')) {
        inCode = !inCode;
      }
      if (!inCode && RegExp(r'^#{1,3} ').hasMatch(line)) {
        flush();
        heading = line.replaceFirst(RegExp(r'^#+ '), '');
        continue;
      }
      buffer.writeln(line);
    }
    flush();
  }
  hits.sort((a, b) => b.score.compareTo(a.score));
  return [
    for (final hit in hits.take(limit))
      {
        'page': hit.page,
        'section': hit.heading,
        'text': hit.text.length > 4000
            ? '${hit.text.substring(0, 4000)}\n[...]'
            : hit.text,
      },
  ];
}

/// The `conventions` tool: what an agent must know before writing code.
const String daravelConventions = '''
# Daravel conventions

Daravel is a Laravel-style backend framework for Dart, compiled to one
native binary. Laravel and Daravel can share a database, so wire and
storage formats (422 and error JSON, paginator and resource JSON,
personal_access_tokens, bcrypt \$2y\$, Crypt payloads, migrations/cache/jobs
tables) are Laravel's on purpose: do not change them.

## No reflection, no build_runner
Everything Laravel discovers automatically is an explicit list in
bootstrap/: migrations.dart, seeders.dart, jobs.dart (JobDefinition(name,
fromJson)), policies.dart, listeners.dart, commands.dart. Use the
generators (dartisan make:model, make:migration, make:controller,
make:request, make:job, ...): they write the file and add it to the
registry between the // <dartisan:imports> and // <dartisan:entries>
markers. A file left out of a registry is reported by `dartisan lint`
(registry_entry_missing).

## Models
final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts', factory: Post.new,
    relations: {'user': () => BelongsTo<User>(() => User.definition)});
  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;
}
Keep the explicit ModelDefinition<T> type and relation thunks (inference
cycles). Every model is listed in bootstrap/models.dart (make:model adds
it; the "models" tool and `dartisan model:show` read it). Typed accessors live between // <dartisan:accessors> markers and
are rewritten by `dartisan model:sync` from the database schema.

## Routes and validation
routes/api.dart registers routes: router.post('/posts', controller.store)
.validates(StorePostRequest.new).returns(...).action('PostController@store').
Rules use the Laravel string DSL ('required|email|max:255') or
Rules.required().email(). Invalid input answers 422 in Laravel's format.

## Time
Domain time (timestamps, token expiry, cache TTL, schedules, signed URLs)
uses Clock.now(), so tests can freezeTime()/travel(). Wall-clock concerns
(timeouts, log timestamps) use DateTime.now().

## Facades and scopes
DB, Auth, Cache, Queue, Event, Log, Storage, Hash, Crypt, Gate, Schema,
Config resolve the current request, job or command scope. DB.transaction
nests as savepoints; queue dispatch and Event.dispatchAfterCommit wait for
the outer commit.

## Checks
dart analyze --fatal-infos (strict casts, inference and raw types), dart
format, `dartisan lint` (daravel_lints rules such as
no_sql_string_interpolation and invalid_validation_rule; suppress with
// daravel-lint-ignore: <rule>) and `dartisan test`. Tests use
package:daravel_test: TestClient, refreshDatabase, assertions, time travel.
''';

/// `mcp:serve [--allow-write]`: a Model Context Protocol server on stdio
/// for AI coding agents (Claude Code, Cursor, ...), bound to this project.
///
/// stdout carries only protocol messages; application output (logs) goes to
/// stderr.
final class McpServeCommand extends DaravelCommand {
  /// The `dartisan mcp:serve` command.
  McpServeCommand(super.createApp) {
    argParser.addFlag(
      'allow-write',
      negatable: false,
      help:
          'Also offer run_command (make:*, migrate, test, ...); destructive '
          'commands stay refused in production.',
    );
    argParser.addMultiOption(
      'allow-command',
      splitCommas: false,
      valueHelp: 'name',
      help:
          'With --allow-write, also offer this command (a project command); '
          'repeat for more. Long-running commands, and in production the '
          'ones that change data, stay refused.',
    );
  }

  @override
  String get name => 'mcp:serve';

  @override
  String get description =>
      'Serve project context to AI agents over MCP (stdio).';

  @override
  Future<int> run() {
    final protocol = stdout;
    final allowWrite = argResults!['allow-write'] as bool;
    final allowed = (argResults!['allow-command'] as List<String>).toSet();
    if (allowed.isNotEmpty && !allowWrite) {
      usageException('--allow-command needs --allow-write.');
    }
    for (final name in allowed) {
      final command = runner?.commands[name];
      if (command == null || command.name != name) {
        usageException(
          '--allow-command=$name: no dartisan command has that name'
          '${command == null ? '' : ' (it is an alias of ${command.name})'}.',
        );
      }
      if (mcpNeverOffered.contains(name)) {
        usageException('--allow-command=$name: $name runs until stopped.');
      }
    }
    stderr.writeln('[mcp] Daravel MCP Server running on stdio (JSON-RPC 2.0).');
    stderr.writeln(
      '[mcp] Waiting for AI client messages (Cursor, Claude, Antigravity)...',
    );
    stderr.writeln('[mcp] (Press Ctrl+C to stop)');
    return IOOverrides.runZoned(
      () => withApp((app) async {
        await McpServer(
          app,
          allowWrite: allowWrite,
          tools: mcpToolsOf(runner),
          runner: runner,
          allowedCommands: allowed,
        ).serve(stdin, protocol);
        return 0;
      }),
      stdout: () => stderr,
    );
  }
}

/// The `daravel` entry `mcp:install` writes to `.mcp.json`.
const Map<String, Object?> mcpServerEntry = {
  'command': 'dart',
  'args': ['run', 'bin/dartisan.dart', 'mcp:serve'],
};

/// The entry for a DDEV project: its packages are resolved inside the web
/// container, so the server runs there (`ddev dartisan`).
const Map<String, Object?> mcpDdevServerEntry = {
  'command': 'ddev',
  'args': ['dartisan', 'mcp:serve'],
};

/// `.ddev/commands/web/dartisan`: `ddev dartisan <command>` runs the
/// project's CLI in the web container.
const String ddevDartisanCommand = r"""#!/usr/bin/env bash

## Description: Run the project's dartisan (Daravel's artisan) in the web container
## Usage: dartisan [command] [arguments]
## Example: "ddev dartisan migrate" or "ddev dartisan route:list"

# The packages are resolved inside the container, so the project's CLI runs
# here, not with a dart on the host.
cd /var/www/html
exec dart run bin/dartisan.dart "$@"
""";

/// Whether [root] is a DDEV project (`.ddev/config.yaml`).
bool isDdevProject(String root) =>
    File(p.join(root, '.ddev', 'config.yaml')).existsSync();

/// The `.mcp.json` entry for the project at [root].
Map<String, Object?> mcpServerEntryFor(String root) =>
    isDdevProject(root) ? mcpDdevServerEntry : mcpServerEntry;

const String _guidelinesStart = '<!-- daravel:guidelines -->';
const String _guidelinesEnd = '<!-- /daravel:guidelines -->';

/// The Daravel section of the agent guidelines (`AGENTS.md`); [server] is
/// how the MCP server is started.
String agentGuidelines({
  String server = 'dart run bin/dartisan.dart mcp:serve',
}) {
  final conventions = daravelConventions
      .replaceFirst(RegExp(r'^# .*\n\n'), '')
      .replaceAll(RegExp(r'^## ', multiLine: true), '### ');
  return '''
$_guidelinesStart
## Daravel

This project uses Daravel $daravelVersion, a Laravel-style backend framework
for Dart. The `daravel` MCP server (`$server`)
answers with the application as it is: call `conventions` first, `routes`,
`models` and `schema` before changing code, `docs_search` for framework
APIs, and `db_query`, `read_logs` and `last_error` while debugging.

$conventions$_guidelinesEnd
''';
}

/// Registers the `daravel` MCP server in [root]`/.mcp.json` (other servers
/// are kept) and writes the Daravel section of [root]`/`[guidelines]
/// between markers, so running it again only refreshes that section.
///
/// In a DDEV project the server runs in the web container
/// (`ddev dartisan mcp:serve`, adding `.ddev/commands/web/dartisan` when
/// missing), and an existing entry still at the host default, which cannot
/// resolve the container's packages, is replaced. Returns the files it
/// changed.
List<String> installMcp(
  String root, {
  String guidelines = 'AGENTS.md',
  bool force = false,
}) {
  final changed = <String>[];
  final config = File(p.join(root, '.mcp.json'));
  final Map<String, Object?> json = config.existsSync()
      ? switch (jsonDecode(config.readAsStringSync())) {
          final Map<String, Object?> map => map,
          _ => throw const FormatException('.mcp.json is not a JSON object.'),
        }
      : {};
  final servers = switch (json['mcpServers']) {
    final Map<String, Object?> map => map,
    _ => <String, Object?>{},
  };
  final ddev = isDdevProject(root);
  final entry = mcpServerEntryFor(root);
  final existing = servers['daravel'];
  // Compared as JSON, the form it has in .mcp.json.
  final hostDefault =
      ddev && jsonEncode(existing) == jsonEncode(mcpServerEntry);
  if (force || existing == null || hostDefault) {
    servers['daravel'] = entry;
    json['mcpServers'] = servers;
    config.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );
    changed.add(config.path);
  }

  if (ddev) {
    final command = File(p.join(root, '.ddev', 'commands', 'web', 'dartisan'));
    if (!command.existsSync()) {
      command
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(ddevDartisanCommand);
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', command.path]);
      }
      changed.add(command.path);
    }
  }

  final file = File(p.join(root, guidelines));
  final section = agentGuidelines(
    server: ddev
        ? 'ddev dartisan mcp:serve'
        : 'dart run bin/dartisan.dart mcp:serve',
  );
  final current = file.existsSync() ? file.readAsStringSync() : null;
  final String next;
  if (current == null) {
    next = '# Agent guidelines\n\n$section';
  } else {
    final start = current.indexOf(_guidelinesStart);
    final end = current.indexOf(_guidelinesEnd);
    next = start != -1 && end > start
        ? current.substring(0, start) +
              section.trimRight() +
              current.substring(end + _guidelinesEnd.length)
        : '${current.trimRight()}\n\n$section';
  }
  if (next != current) {
    file.writeAsStringSync(next);
    changed.add(file.path);
  }
  return changed;
}

/// `mcp:install [--guidelines=AGENTS.md] [--force]`: registers the MCP
/// server for AI agents and writes their Daravel guidelines.
final class McpInstallCommand extends Command<int> {
  /// The `dartisan mcp:install` command.
  McpInstallCommand() {
    argParser
      ..addOption(
        'guidelines',
        defaultsTo: 'AGENTS.md',
        help: 'File for the agent guidelines (e.g. CLAUDE.md).',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace an existing "daravel" entry in .mcp.json.',
      );
  }

  @override
  String get name => 'mcp:install';

  @override
  String get description =>
      'Register mcp:serve in .mcp.json and write agent guidelines.';

  @override
  Future<int> run() async {
    final root = ProjectPaths.locate().root;
    final changed = installMcp(
      root,
      guidelines: argResults!['guidelines'] as String,
      force: argResults!['force'] as bool,
    );
    for (final path in changed) {
      stdout.writeln('Wrote ${p.relative(path, from: root)}');
    }
    if (changed.isEmpty) {
      stdout.writeln('Already installed.');
    }
    return 0;
  }
}
