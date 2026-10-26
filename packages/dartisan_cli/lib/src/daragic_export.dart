import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import '../dartisan_cli.dart';

/// The DAM (Daravel Application Model) version written by [buildDam]
/// (BLUEPRINT_DARAGIC §5).
const String damVersion = '1.0';

/// Every DAM section [buildDam] can write, in output order.
const List<String> damSections = [
  'app',
  'env',
  'middleware',
  'routes',
  'models',
  'migrations',
  'schema',
  'schedule',
  'jobs',
  'features',
  'lang',
];

/// What this exporter does not describe yet; listed in `report.unsupported`
/// so nothing is dropped silently (BLUEPRINT_DARAGIC §5.1).
const List<String> damUnsupported = [
  'sources: method bodies (controllers, closures, jobs, scopes, accessors) '
      'need the Dialect IR extractor',
  'migrations: structured operations (only names, order and batches)',
  'schema: indexes and foreign keys',
  'policies, gates, events and listeners, commands, seeders, factories',
  'config: the full config tree',
];

/// The application as a DAM: structure only, deterministic (entities sorted,
/// no timestamps), no secrets (`.env.example` keys and safe defaults only).
/// [only] limits the sections (`meta` and `report` are always there).
Future<Map<String, Object?>> buildDam(
  Application app, {
  Set<String>? only,
  String? projectRoot,
}) async {
  bool wants(String section) => only == null || only.contains(section);
  final appConfig = app.config.section<AppConfig>();
  final dam = <String, Object?>{
    'meta': {
      'damVersion': damVersion,
      'source': {'framework': 'daravel', 'version': daravelVersion},
      'tool': 'dartisan daragic:export',
    },
  };
  if (wants('app')) {
    dam['app'] = {
      'name': appConfig.name,
      'env': appConfig.env,
      'url': appConfig.url,
      'debug': appConfig.debug,
      'timezone': appConfig.timezone,
      'locale': appConfig.locale,
      'fallbackLocale': app.env.string('APP_FALLBACK_LOCALE', 'en'),
    };
  }
  if (wants('env')) {
    dam['env'] = _env(projectRoot ?? app.basePath);
  }
  if (wants('middleware')) {
    dam['middleware'] = _middleware(app.middleware);
  }
  if (wants('routes')) {
    dam['routes'] = _routes(app.router.routes);
  }
  if (wants('models')) {
    dam['models'] = [
      for (final model in app.container.make<ModelRegistry>().models)
        _model(model),
    ]..sort(_byKey('name'));
  }
  if (wants('migrations') || wants('schema')) {
    final (migrations, schema) = await _database(app, wants('schema'));
    if (wants('migrations')) {
      dam['migrations'] = migrations;
    }
    if (wants('schema')) {
      dam['schema'] = schema;
    }
  }
  if (wants('schedule')) {
    dam['schedule'] = [
      for (final task in app.container.make<Schedule>().tasks) _task(task),
    ];
  }
  if (wants('jobs')) {
    dam['jobs'] = [
      for (final name in app.container.make<JobRegistry>().names)
        // The framework's own jobs (`daravel:mail`, ...) are not the
        // application's; Laravel has its own for the same work.
        if (!name.startsWith('daravel:')) {'name': name},
    ]..sort(_byKey('name'));
  }
  if (wants('features')) {
    dam['features'] = [
      for (final name in app.container.make<FeatureManager>().defined)
        {'name': name},
    ]..sort(_byKey('name'));
  }
  if (wants('lang')) {
    final translator = app.container.make<Translator>();
    dam['lang'] = {'lines': translator.lines, 'json': translator.jsonLines};
  }
  dam['report'] = {
    'counts': {
      for (final section in damSections)
        if (dam[section] case final List<Object?> list) section: list.length,
    },
    'unsupported': damUnsupported,
  };
  return canonical(dam)! as Map<String, Object?>;
}

int Function(Map<String, Object?>, Map<String, Object?>) _byKey(String key) =>
    (a, b) => '${a[key]}'.compareTo('${b[key]}');

/// [value] with every map's keys sorted, so the JSON is byte-for-byte stable.
Object? canonical(Object? value) => switch (value) {
  final Map<Object?, Object?> map => {
    for (final key in (map.keys.map((k) => '$k').toList()..sort()))
      key: canonical(map[key]),
  },
  final Iterable<Object?> list => [for (final item in list) canonical(item)],
  _ => value,
};

final RegExp _secret = RegExp(
  r'KEY|SECRET|PASSWORD|TOKEN|PASS$|DSN',
  caseSensitive: false,
);

List<Map<String, Object?>> _env(String root) {
  final file = File(p.join(root, '.env.example'));
  if (!file.existsSync()) {
    return const [];
  }
  final entries = <Map<String, Object?>>[];
  for (final MapEntry(:key, :value) in parseEnvKeys(
    file.readAsStringSync(),
  ).entries) {
    final secret = _secret.hasMatch(key);
    entries.add({
      'key': key,
      'default': secret || value.isEmpty ? null : value,
      'type': switch (value.toLowerCase()) {
        'true' || 'false' => 'bool',
        _ when int.tryParse(value) != null => 'int',
        _ => 'string',
      },
      if (secret) 'secret': true,
    });
  }
  return entries..sort(_byKey('key'));
}

Map<String, Object?> _middleware(MiddlewareRegistry middleware) => {
  'global': [
    for (final m in middleware.orderedGlobal) m.runtimeType.toString(),
  ],
  'groups': {
    for (final name in middleware.groups)
      name: [
        for (final entry in middleware.groupEntries(name))
          entry is String ? entry : entry.runtimeType.toString(),
      ],
  },
  'aliases': middleware.aliases.toList()..sort(),
};

/// Laravel's route URIs have no leading slash (`api/users/{user}`).
String _uri(String path) =>
    path == '/' ? '/' : path.replaceFirst(RegExp('^/'), '');

List<Map<String, Object?>> _routes(Iterable<RouteEntry> routes) {
  final out = <Map<String, Object?>>[];
  for (final route in routes) {
    if ((route.routeName ?? '').startsWith('daravel.')) {
      continue;
    }
    final action = route.actionName;
    final at = action?.indexOf('@') ?? -1;
    final rules = route.documentedRules();
    final response = route.declaredResponse;
    out.add({
      'methods': route.methods,
      'uri': _uri(route.path),
      'name': route.routeName,
      'action': action == null
          ? {'kind': 'closure', 'unsupported': 'source'}
          : {
              'kind': 'controller',
              'class': at < 0 ? action : action.substring(0, at),
              'method': at < 0 ? '__invoke' : action.substring(at + 1),
            },
      'middleware': [
        for (final m in route.middlewareEntries)
          m is String ? m : m.runtimeType.toString(),
      ],
      if (route.constraints.isNotEmpty)
        'where': {
          // Laravel's `where` patterns carry no anchors (`[0-9]+`).
          for (final MapEntry(:key, :value) in route.constraints.entries)
            key: value.pattern
                .replaceFirst(RegExp(r'^\^'), '')
                .replaceFirst(RegExp(r'\$$'), ''),
        },
      if (route.defaultValues.isNotEmpty)
        'defaults': {
          for (final MapEntry(:key, :value) in route.defaultValues.entries)
            key: '$value',
        },
      if (route.formRequest != null)
        'formRequest': route.formRequest.runtimeType.toString(),
      if (rules != null)
        'validation': {
          for (final MapEntry(:key, :value) in rules.entries)
            key: _rules(describeRules(value)),
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
    });
  }
  return out..sort(
    (a, b) =>
        '${a['uri']} ${a['methods']}'.compareTo('${b['uri']} ${b['methods']}'),
  );
}

/// Both forms of BLUEPRINT_DARAGIC §5.4: the DSL and structured rules.
Map<String, Object?> _rules(List<String> dsl) => {
  'dsl': dsl.join('|'),
  'rules': [
    for (final rule in dsl)
      if (rule.indexOf(':') case final colon when colon > 0)
        {
          'name': rule.substring(0, colon),
          // A regex may contain commas: it is one argument.
          'args': rule.startsWith('regex:') || rule.startsWith('not_regex:')
              ? [rule.substring(colon + 1)]
              : [
                  for (final arg in rule.substring(colon + 1).split(','))
                    num.tryParse(arg) ?? arg,
                ],
        }
      else
        {'name': rule},
  ],
};

const Map<String, String> _relationTypes = {
  'HasOne': 'hasOne',
  'HasMany': 'hasMany',
  'BelongsTo': 'belongsTo',
  'BelongsToMany': 'belongsToMany',
  'HasOneThrough': 'hasOneThrough',
  'HasManyThrough': 'hasManyThrough',
  'MorphOne': 'morphOne',
  'MorphMany': 'morphMany',
  'MorphTo': 'morphTo',
  'MorphToMany': 'morphToMany',
  'MorphedByMany': 'morphedByMany',
};

Map<String, Object?> _model(ModelDefinition<Model> model) {
  final described = describeModel(model);
  return {
    'name': described['class'],
    'fqcn': model.morphClass,
    'table': model.table,
    if (model.connection != null) 'connection': model.connection,
    'key': {
      'name': model.primaryKey,
      'type': model.keyType.name,
      'incrementing': model.keyType == KeyType.autoInt,
    },
    'fillable': model.fillable,
    'guarded': model.guarded,
    'casts': described['casts'],
    'hidden': model.hidden,
    'visible': model.visible,
    'appends': model.appends,
    'timestamps': model.timestamps,
    'createdAt': model.createdAt,
    'updatedAt': model.updatedAt,
    'softDeletes': model.softDeletes,
    'deletedAt': model.deletedAt,
    'perPage': model.perPage,
    'touches': model.touches,
    'with': model.withRelations,
    'scopes': model.scopes.keys.toList()..sort(),
    'relations': [
      for (final name in model.relationNames)
        _relation(model.requireRelation(name)),
    ]..sort(_byKey('name')),
    if (model.observers.isNotEmpty || model.accessors.isNotEmpty)
      'unsupported': ['sources of scopes, accessors, mutators and observers'],
  };
}

Map<String, Object?> _relation(Relation<Model> relation) {
  final described = describeRelation(relation);
  final type = '${described['type']}';
  String fqcn(ModelDefinition<Model> Function() definition) =>
      definition().morphClass;
  return {
    'name': relation.name,
    'type': _relationTypes[type] ?? type,
    'related': switch (relation) {
      MorphTo(:final types) => [for (final t in types) fqcn(t)],
      _ => relation.related.morphClass,
    },
    ...switch (relation) {
      MorphToMany() => {
        'pivot': {
          'table': relation.pivotTable,
          'foreignPivotKey': relation.foreignPivotKey,
          'relatedPivotKey': relation.relatedPivotKey,
        },
        'morph': {'type': relation.morphType, 'name': relation.morphName},
      },
      BelongsToMany() => {
        'pivot': {
          'table': relation.pivotTable,
          'foreignPivotKey': relation.foreignPivotKey,
          'relatedPivotKey': relation.relatedPivotKey,
        },
      },
      MorphMany() => {
        'foreignKey': relation.foreignKey,
        'localKey': relation.localKey,
        'morph': {'type': relation.morphType, 'name': relation.morphName},
      },
      HasMany() => {
        'foreignKey': relation.foreignKey,
        'localKey': relation.localKey,
      },
      HasManyThrough() => {
        'through': {
          'model': fqcn(relation.through),
          'firstKey': relation.firstKey,
          'secondKey': relation.secondKey,
        },
      },
      BelongsTo() => {
        'foreignKey': relation.foreignKey,
        'ownerKey': relation.ownerKey,
      },
      MorphTo() => {
        'morph': {
          'type': relation.morphType,
          'id': relation.foreignKey,
          'name': relation.morphName,
        },
      },
      _ => const <String, Object?>{},
    },
  };
}

Future<(List<Object?>, Object?)> _database(
  Application app,
  bool withSchema,
) async {
  final migrator = app.container.make<Migrator>();
  final batches = <String, int>{};
  Object? schema;
  try {
    await app.run(() async {
      final builder = SchemaBuilder(await DB.manager.executor());
      if (await builder.hasTable('migrations')) {
        for (final row in await DB.table('migrations').get()) {
          batches['${row['migration']}'] = (row['batch']! as num).toInt();
        }
      }
      if (withSchema) {
        schema = [
          for (final table in (await builder.getTables())..sort())
            {
              'name': table,
              'columns': [
                for (final column in await builder.getColumns(table))
                  {
                    'name': column.name,
                    'type': column.type,
                    'nullable': column.nullable,
                    'default': column.defaultValue,
                    'primary': column.primary,
                    'autoIncrement': column.autoIncrement,
                  },
              ],
            },
        ];
      }
    });
  } on Object catch (error) {
    // The structure still exports without a reachable database.
    schema = {'unavailable': '$error'.split('\n').first};
  }
  return (
    [
      for (final migration in migrator.migrations)
        {
          'name': migration.name,
          'class': migration.runtimeType.toString(),
          'batch': batches[migration.name],
        },
    ],
    schema,
  );
}

Map<String, Object?> _task(ScheduledTask task) => {
  'cron': task.cron.expression,
  'timezone': task.timezoneName,
  'description': task.name,
  ...switch (task.action) {
    CommandAction(:final command, :final args) => {
      'kind': 'command',
      'command': command,
      'args': args,
    },
    JobAction(:final job, :final queue) => {
      'kind': 'job',
      'job': job.jobName,
      'queue': ?queue,
    },
    ExecAction(:final executable, :final args) => {
      'kind': 'exec',
      'command': [executable, ...args].join(' '),
    },
    CallbackAction() => {'kind': 'call', 'unsupported': 'source'},
  },
  'withoutOverlapping': task.overlapProtected,
  'onOneServer': task.singleServer,
  'runInBackground': task.runsInBackground,
};

/// `daragic.lock`: the DAM version and a SHA-256 per section and per entity,
/// for incremental merges (BLUEPRINT_DARAGIC §5.5).
Map<String, Object?> damLock(Map<String, Object?> dam) {
  String hash(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(canonical(value)))).toString();
  String id(String section, Map<String, Object?> entity) => switch (section) {
    'routes' => '${(entity['methods']! as List).join('|')} ${entity['uri']}',
    'env' => '${entity['key']}',
    'schedule' => '${entity['cron']} ${entity['description']}',
    _ => '${entity['name']}',
  };
  return {
    'damVersion': damVersion,
    'sections': {
      for (final MapEntry(:key, :value) in dam.entries)
        if (key != 'meta' && key != 'report') key: hash(value),
    },
    'entities': {
      for (final MapEntry(:key, :value) in dam.entries)
        if (value is List<Object?>)
          for (final entity in value.whereType<Map<String, Object?>>())
            '$key:${id(key, entity)}': hash(entity),
    },
  };
}

/// `daragic:export [--out=dam] [--only=routes,models,...]`: writes the
/// application's DAM (`dam.json`) and `daragic.lock`.
final class DaragicExportCommand extends DaravelCommand {
  DaragicExportCommand(super.createApp) {
    argParser
      ..addOption('out', defaultsTo: 'dam', help: 'Output directory.')
      ..addOption(
        'only',
        help: 'Comma-separated sections: ${damSections.join(', ')}.',
      );
  }

  @override
  String get name => 'daragic:export';

  @override
  String get description =>
      'Export the application model (DAM) for daragic (routes, models, ...).';

  @override
  Future<int> run() => withApp((app) async {
    final args = argResults!;
    final onlyOption = args['only'] as String?;
    final only = onlyOption?.split(',').map((s) => s.trim()).toSet();
    final unknown = only?.difference(damSections.toSet()) ?? const {};
    if (unknown.isNotEmpty) {
      throw UsageException('Unknown section(s): ${unknown.join(', ')}.', usage);
    }
    final root = ProjectPaths.locate(app.basePath).root;
    final dam = await buildDam(app, only: only, projectRoot: root);
    final out = Directory(p.join(root, args['out'] as String))
      ..createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    File(p.join(out.path, 'dam.json'))
        .writeAsStringSync('${encoder.convert(dam)}\n');
    File(p.join(out.path, 'daragic.lock'))
        .writeAsStringSync('${encoder.convert(damLock(dam))}\n');
    final counts = (dam['report']! as Map)['counts']! as Map;
    stdout.writeln(
      'Wrote ${p.relative(out.path, from: root)}/dam.json '
      '(${counts.entries.map((e) => '${e.value} ${e.key}').join(', ')}).',
    );
    stdout.writeln(
      'Not exported yet: method bodies and the other items in '
      'report.unsupported.',
    );
    return 0;
  });
}
