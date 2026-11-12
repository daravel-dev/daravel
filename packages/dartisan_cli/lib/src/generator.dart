import 'dart:io';

import 'package:daravel/daravel.dart' show Str;
import 'package:path/path.dart' as p;

import 'region_format.dart';
import 'request_sync.dart';
import 'stubs.dart';

/// Locates a Daravel project (BLUEPRINT_V2 §8.3): a directory with a
/// `pubspec.yaml` and a `bootstrap/` folder.
final class ProjectPaths {
  /// The paths of the project at [root], whose package is [packageName].
  ProjectPaths(this.root, {required this.packageName});

  /// Finds the project root starting at [start] (defaults to the cwd),
  /// walking up until `pubspec.yaml` + `bootstrap/` are found.
  factory ProjectPaths.locate([String? start]) {
    var dir = Directory(start ?? Directory.current.path).absolute;
    while (true) {
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
      if (pubspec.existsSync() &&
          Directory(p.join(dir.path, 'bootstrap')).existsSync()) {
        final name = RegExp(
          r'^name:\s*(\S+)',
          multiLine: true,
        ).firstMatch(pubspec.readAsStringSync())?.group(1);
        if (name == null) {
          throw StateError('pubspec.yaml in ${dir.path} has no name.');
        }
        return ProjectPaths(dir.path, packageName: name);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError(
          'Not inside a Daravel project (no pubspec.yaml with a bootstrap/ directory found).',
        );
      }
      dir = parent;
    }
  }

  /// The project's root.
  final String root;

  /// The project's package name.
  final String packageName;

  String _app(List<String> parts) => p.joinAll([root, 'lib', 'app', ...parts]);

  /// `lib/app/models`.
  String get models => _app(['models']);

  /// `lib/app/http/controllers`.
  String get controllers => _app(['http', 'controllers']);

  /// `lib/app/http/requests`.
  String get requests => _app(['http', 'requests']);

  /// `lib/app/http/middleware`.
  String get middleware => _app(['http', 'middleware']);

  /// `lib/app/http/resources`.
  String get resources => _app(['http', 'resources']);

  /// `lib/app/jobs`.
  String get jobs => _app(['jobs']);

  /// `lib/app/events`.
  String get events => _app(['events']);

  /// `lib/app/listeners`.
  String get listeners => _app(['listeners']);

  /// `lib/app/policies`.
  String get policies => _app(['policies']);

  /// `lib/app/query_filters`.
  String get queryFilters => _app(['query_filters']);

  /// `lib/app/rules`.
  String get rules => _app(['rules']);

  /// `lib/app/mail`.
  String get mail => _app(['mail']);

  /// `lib/app/notifications`.
  String get notifications => _app(['notifications']);

  /// `lib/app/observers`.
  String get observers => _app(['observers']);

  /// `lib/app/providers`.
  String get providers => _app(['providers']);

  /// `lib/app/console/commands`.
  String get commands => _app(['console', 'commands']);

  /// `database/migrations`.
  String get migrations => p.join(root, 'database', 'migrations');

  /// `database/seeders`.
  String get seeders => p.join(root, 'database', 'seeders');

  /// `database/factories`.
  String get factories => p.join(root, 'database', 'factories');

  /// `test/feature`.
  String get featureTests => p.join(root, 'test', 'feature');

  /// `test/unit`.
  String get unitTests => p.join(root, 'test', 'unit');

  /// `stubs`, holding the project's own templates.
  String get stubs => p.join(root, 'stubs');

  /// `bootstrap/migrations.dart`.
  String get migrationsRegistry => p.join(root, 'bootstrap', 'migrations.dart');

  /// `bootstrap/seeders.dart`.
  String get seedersRegistry => p.join(root, 'bootstrap', 'seeders.dart');

  /// `bootstrap/jobs.dart`.
  String get jobsRegistry => p.join(root, 'bootstrap', 'jobs.dart');

  /// `bootstrap/models.dart`.
  String get modelsRegistry => p.join(root, 'bootstrap', 'models.dart');

  /// `lib/app/models/models.dart`: every model in one import, with the
  /// relation path getters `model:sync` writes next to each.
  String get modelsBarrel => p.join(models, 'models.dart');

  /// `bootstrap/policies.dart`.
  String get policiesRegistry => p.join(root, 'bootstrap', 'policies.dart');

  /// `bootstrap/query_filters.dart`.
  String get queryFiltersRegistry =>
      p.join(root, 'bootstrap', 'query_filters.dart');

  /// `bootstrap/listeners.dart`.
  String get listenersRegistry => p.join(root, 'bootstrap', 'listeners.dart');

  /// `bootstrap/commands.dart`.
  String get commandsRegistry => p.join(root, 'bootstrap', 'commands.dart');
}

/// A model a generated job carries (`make:job --model=User:candidate`): a
/// `ModelRef<User> candidate` field.
final class JobModelField {
  /// The field [field] referencing a [model].
  const JobModelField(this.model, this.field);

  /// Reads `Model` or `Model:field` (the field defaults to the model's name
  /// in camel case); null when either part is not an identifier.
  static JobModelField? tryParse(String spec) {
    final parts = spec.split(':');
    if (parts.length > 2) {
      return null;
    }
    final model = Naming.pascal(parts.first.trim());
    final field = parts.length == 2
        ? parts[1].trim()
        : Naming.camel(parts.first.trim());
    final identifier = RegExp(r'^[A-Za-z][A-Za-z0-9]*$');
    if (!identifier.hasMatch(model) ||
        !RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(field)) {
      return null;
    }
    return JobModelField(model, field);
  }

  /// The model class, such as `User`.
  final String model;

  /// The field name, such as `candidate`.
  final String field;
}

/// Naming helpers shared by generators.
abstract final class Naming {
  /// `blog_post` or `blog post` as `BlogPost`.
  static String pascal(String input) => input
      .split(RegExp(r'[^A-Za-z0-9]+|(?<=[a-z0-9])(?=[A-Z])'))
      .where((s) => s.isNotEmpty)
      .map((s) => s[0].toUpperCase() + s.substring(1))
      .join();

  /// `BlogPost` as `blog_post`.
  static String snake(String input) => input
      .replaceAllMapped(RegExp(r'(?<=[a-z0-9])([A-Z])'), (m) => '_${m[1]}')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '')
      .toLowerCase();

  /// `BlogPost` as `blog-post`.
  static String kebab(String input) => snake(input).replaceAll('_', '-');

  /// `BlogPost` as `blogPost`.
  static String camel(String input) {
    final pascalCase = pascal(input);
    return pascalCase.isEmpty
        ? ''
        : pascalCase[0].toLowerCase() + pascalCase.substring(1);
  }

  /// `User` → `users`, `Category` → `categories`, `Address` → `addresses`,
  /// `Stimulus` → `stimuli`: Laravel's English rules ([Str.plural]),
  /// irregular and Latin plurals included.
  static String plural(String word) => Str.plural(word);

  /// Table name for a model class (`BlogPost` → `blog_posts`).
  static String table(String model) => plural(snake(model));

  /// Appends [suffix] unless [name] already ends with it.
  static String withSuffix(String name, String suffix) {
    final pascalName = pascal(name);
    return pascalName.endsWith(suffix) ? pascalName : '$pascalName$suffix';
  }

  /// `yyyy_MM_dd_HHmmss` timestamp for migration files.
  static String timestamp([DateTime? now]) {
    final t = (now ?? DateTime.now()).toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}_${two(t.month)}_${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

/// Result of a generation step.
final class GeneratedFile {
  /// A file at [path] that was written, overwritten or skipped.
  const GeneratedFile(
    this.path, {
    this.overwritten = false,
    this.skipped = false,
  });

  /// The file's path, relative to the project.
  final String path;

  /// Whether an existing file was replaced (`--force`).
  final bool overwritten;

  /// Whether the file existed and was left alone.
  final bool skipped;

  @override
  String toString() => skipped
      ? 'skipped $path'
      : '${overwritten ? 'updated' : 'created'} $path';
}

/// The models barrel (`lib/app/models/models.dart`): one `export` per model
/// between `// <dartisan:exports>` and `// </dartisan:exports>`, kept by
/// `make:model`, so one import brings every model and its relation path
/// getters.
abstract final class ModelsBarrel {
  /// The line opening the barrel's exports.
  static const String start = '// <dartisan:exports>';

  /// The line closing the barrel's exports.
  static const String end = '// </dartisan:exports>';

  /// [content] with `export '[file]';` among its exports, kept sorted; null
  /// when it is there already or the file has no exports region.
  static String? add(String content, String file) {
    final from = content.indexOf(start);
    final to = content.indexOf(end);
    if (from == -1 || to < from) {
      return null;
    }
    final newline = String.fromCharCode(10);
    final line = "export '$file';";
    final exports = {
      for (final l in content.substring(from + start.length, to).split(newline))
        if (l.trim().isNotEmpty) l.trim(),
    };
    if (!exports.add(line)) {
      return null;
    }
    final sorted = exports.toList()..sort();
    // dart format keeps a blank line between the last directive and the
    // comment closing the region.
    return [
      content.substring(0, from + start.length),
      ...sorted,
      '',
      content.substring(to),
    ].join(newline);
  }
}

/// Inserts import and entry lines into registry files that carry
/// `// <dartisan:imports>` and `// <dartisan:entries>` regions (ADR-002).
/// Idempotent: existing lines are not duplicated; imports stay sorted.
abstract final class RegistryPatcher {
  /// The line opening a registry's import region.
  static const String importsStart = '// <dartisan:imports>';

  /// The line closing a registry's import region.
  static const String importsEnd = '// </dartisan:imports>';

  /// The line opening a registry's entries region.
  static const String entriesStart = '// <dartisan:entries>';

  /// The line closing a registry's entries region.
  static const String entriesEnd = '// </dartisan:entries>';

  /// Returns the patched content, or `null` when nothing changed.
  static String? patch(
    String content, {
    required String importLine,
    required String entryLine,
  }) {
    var changed = false;
    var result = content;
    final importsRegion = _region(result, importsStart, importsEnd);
    final imports = importsRegion.lines
        .where((l) => l.trim().isNotEmpty)
        .toSet();
    if (imports.add(importLine)) {
      final sorted = imports.toList()..sort();
      result = _replaceRegion(result, importsStart, importsEnd, sorted);
      changed = true;
    }
    final entriesRegion = _region(result, entriesStart, entriesEnd);
    final entries = entriesRegion.lines
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (!entries.any((l) => l.trim() == entryLine.trim())) {
      entries.add(entryLine);
      result = _replaceRegion(result, entriesStart, entriesEnd, entries);
      changed = true;
    }
    return changed ? result : null;
  }

  static ({int start, int end, List<String> lines}) _region(
    String content,
    String open,
    String close,
  ) {
    final start = content.indexOf(open);
    final end = content.indexOf(close);
    if (start == -1 || end == -1 || end < start) {
      throw StateError(
        'Registry file is missing the "$open" / "$close" markers; '
        'restore them or pass --no-registry.',
      );
    }
    final inner = content.substring(start + open.length, end);
    final lines = inner.split('\n').map((l) => l.trimRight()).toList();
    return (start: start, end: end, lines: lines);
  }

  static String _replaceRegion(
    String content,
    String open,
    String close,
    List<String> lines,
  ) {
    final region = _region(content, open, close);
    // Keep the closing marker's indentation.
    final lineStart = content.lastIndexOf('\n', region.end - 1) + 1;
    final indent = content.substring(lineStart, region.end);
    final body = lines.isEmpty ? '\n' : '\n${lines.join('\n')}\n';
    return content.substring(0, region.start + open.length) +
        body +
        (indent.trim().isEmpty ? indent : '') +
        content.substring(region.end);
  }

  /// A fresh list registry (`final List<Migration> migrations = [...]`).
  static String template({
    required String header,
    required String listType,
    required String listName,
    String import = "import 'package:daravel/daravel.dart';",
  }) =>
      '''
$header
$import
$importsStart
$importsEnd

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<$listType> $listName = <$listType>[
  $entriesStart
  $entriesEnd
];
''';

  /// A fresh map registry (`final Map<Type, ...> queryFilters = {...}`).
  static String mapTemplate({
    required String header,
    required String mapType,
    required String mapName,
    String import = "import 'package:daravel/daravel.dart';",
  }) =>
      '''
$header
$import
$importsStart
$importsEnd

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final $mapType $mapName = {
  $entriesStart
  $entriesEnd
};
''';

  /// A fresh function registry (`void registerPolicies(AuthorizationGate gate)`).
  static String functionTemplate({
    required String header,
    required String signature,
  }) =>
      '''
$header
import 'package:daravel/daravel.dart';
$importsStart
$importsEnd

/// Maintained by `dartisan make:*`; entries may also be added by hand.
$signature {
  $entriesStart
  $entriesEnd
}
''';
}

/// Writes generated files and keeps registries in sync.
final class Generator {
  /// A generator writing into [paths].
  Generator(
    this.paths, {
    this.force = false,
    this.dryRun = false,
    this.updateRegistries = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Where files go.
  final ProjectPaths paths;

  /// Whether existing files are overwritten.
  final bool force;

  /// Whether files are only reported, not written.
  final bool dryRun;

  /// Whether the `bootstrap/` registries are patched.
  final bool updateRegistries;
  final DateTime Function() _clock;

  /// The files handled, in order.
  final List<GeneratedFile> log = <GeneratedFile>[];

  /// Manual follow-up steps printed after generation.
  final List<String> hints = <String>[];

  String get _package => paths.packageName;

  /// The template for [name]: the project's `stubs/<name>.stub` when it
  /// exists, otherwise the built-in one.
  String stub(String name) {
    final custom = File(p.join(paths.stubs, '$name.stub'));
    if (custom.existsSync()) {
      return custom.readAsStringSync();
    }
    final builtIn = builtInStubs[name];
    if (builtIn == null) {
      throw ArgumentError.value(name, 'name', 'Unknown stub.');
    }
    return builtIn;
  }

  GeneratedFile _render(
    String path,
    String stubName,
    Map<String, String> values,
  ) => _write(path, renderStub(stub(stubName), values));

  // ---------------------------------------------------------------------------
  // Generators
  // ---------------------------------------------------------------------------

  /// A model, its migration and its registry entry (`make:model`).
  GeneratedFile model(String name, {String? table, bool softDeletes = false}) {
    final className = Naming.pascal(name);
    final file = _render(
      p.join(paths.models, '${Naming.snake(className)}.dart'),
      'model',
      {
        'class': className,
        'table': table ?? Naming.table(className),
        'softDeletes': softDeletes ? '\n    softDeletes: true,' : '',
      },
    );
    // Only projects that keep a model registry (created by `dartisan new`
    // since 1.3): creating one here would leave older models unregistered.
    if (File(paths.modelsRegistry).existsSync()) {
      _register(
        file,
        paths.modelsRegistry,
        '',
        "import 'package:$_package/app/models/${Naming.snake(className)}.dart';",
        '  $className.definition,',
      );
    }
    // The models barrel, in projects that have one (`dartisan new` since
    // 1.28): model:sync only hints at it, never creates it.
    final barrel = File(paths.modelsBarrel);
    if (updateRegistries && !file.skipped && barrel.existsSync()) {
      final patched = ModelsBarrel.add(
        barrel.readAsStringSync(),
        '${Naming.snake(className)}.dart',
      );
      if (patched != null) {
        if (!dryRun) {
          barrel.writeAsStringSync(patched);
        }
        log.add(GeneratedFile(barrel.path, overwritten: true));
      }
    }
    return file;
  }

  /// A migration creating or changing a table (`make:migration`).
  GeneratedFile migration(String name, {String? create, String? table}) {
    final snake = Naming.snake(name);
    final stamp = Naming.timestamp(_clock());
    final className = Naming.pascal(snake);
    final stubName = create != null
        ? 'migration.create'
        : table != null
        ? 'migration.update'
        : 'migration';
    final file = _render(
      p.join(paths.migrations, 'm_${stamp}_$snake.dart'),
      stubName,
      {
        'class': className,
        'name': '${stamp}_$snake',
        'table': create ?? table ?? '',
      },
    );
    _register(
      file,
      paths.migrationsRegistry,
      RegistryPatcher.template(
        header: '// Migration registry (explicit, AOT-friendly). See BLUEPRINT_V2 ADR-002.',
        listType: 'Migration',
        listName: 'migrations',
      ),
      "import '../database/migrations/m_${stamp}_$snake.dart';",
      '  const $className(),',
    );
    return file;
  }

  /// A seeder (`make:seeder`).
  GeneratedFile seeder(String name) {
    final className = Naming.pascal(name);
    final file = _render(
      p.join(paths.seeders, '${Naming.snake(className)}.dart'),
      'seeder',
      {'class': className},
    );
    _register(
      file,
      paths.seedersRegistry,
      RegistryPatcher.template(
        header: '// Seeder registry (explicit, AOT-friendly). The first entry is the root seeder.',
        listType: 'Seeder',
        listName: 'seeders',
      ),
      "import '../database/seeders/${Naming.snake(className)}.dart';",
      '  const $className(),',
    );
    return file;
  }

  /// A model factory (`make:factory`).
  GeneratedFile factory(String name, {String? model}) {
    final modelName = Naming.pascal(
      model ?? name.replaceAll(RegExp(r'Factory$'), ''),
    );
    return _render(
      p.join(paths.factories, '${Naming.snake(modelName)}_factory.dart'),
      'factory',
      {
        'model': modelName,
        'modelFile': Naming.snake(modelName),
        'function': '${Naming.camel(modelName)}Factory',
        'package': _package,
      },
    );
  }

  /// A controller, plain or resource (`make:controller`).
  GeneratedFile controller(
    String name, {
    bool api = false,
    bool resource = false,
    String? model,
  }) {
    final className = Naming.withSuffix(name, 'Controller');
    final modelName = model == null ? null : Naming.pascal(model);
    final stubName = modelName != null
        ? 'controller.model.api'
        : (api || resource)
        ? 'controller.api'
        : 'controller';
    return _render(
      p.join(paths.controllers, '${Naming.snake(className)}.dart'),
      stubName,
      {
        'class': className,
        'model': modelName ?? '',
        'modelFile': modelName == null ? '' : Naming.snake(modelName),
        'param': modelName == null ? '' : Naming.snake(modelName),
        'resource': modelName == null ? '' : Naming.table(modelName),
        'package': _package,
      },
    );
  }

  /// A form request (`make:request`).
  ///
  /// With `daravel_test` in the project, also its test
  /// (`test/unit/requests/<name>_test.dart`): `expectFormRequestTyped`
  /// reads every field of a valid sample input as its declared type.
  GeneratedFile request(String name) {
    final className = Naming.withSuffix(name, 'Request');
    final snake = Naming.snake(className);
    final made = renderStub(stub('request'), {'class': className});
    // The region as request:sync writes it (its lines depend on the length
    // of the class name), so a fresh request is already in sync.
    final file = _write(
      p.join(paths.requests, '$snake.dart'),
      syncRequestSource(
            made,
            formatter: RegionFormatter.forProject(paths.root),
          ).source ??
          made,
    );
    if (_dependsOn('daravel_test')) {
      _render(
        p.join(paths.unitTests, 'requests', '${snake}_test.dart'),
        'request.test',
        {'class': className, 'file': snake, 'package': _package},
      );
    }
    return file;
  }

  /// A middleware (`make:middleware`).
  GeneratedFile middleware(String name) {
    final className = Naming.withSuffix(name, 'Middleware');
    return _render(
      p.join(paths.middleware, '${Naming.snake(className)}.dart'),
      'middleware',
      {'class': className},
    );
  }

  /// A queued job and its registry entry (`make:job`). Each of [models]
  /// becomes a `ModelRef` field, saved as its id and tagged for monitoring:
  /// `HorizonTags.model(field)` when the project depends on
  /// `daravel_horizon`, `'User:${field.id}'` otherwise.
  GeneratedFile job(String name, {List<JobModelField> models = const []}) {
    final className = Naming.pascal(name);
    final path = p.join(paths.jobs, '${Naming.snake(className)}.dart');
    final values = {'class': className, 'jobName': Naming.kebab(className)};
    final file = models.isEmpty
        ? _render(path, 'job', values)
        : _render(path, 'job.model', {...values, ..._jobModelValues(models)});
    _register(
      file,
      paths.jobsRegistry,
      RegistryPatcher.template(
        header: '// Job registry (explicit, AOT-friendly): name → factory from JSON.',
        listType: 'JobDefinition',
        listName: 'jobs',
      ),
      "import 'package:$_package/app/jobs/${Naming.snake(className)}.dart';",
      '  JobDefinition($className.name, $className.fromJson),',
    );
    return file;
  }

  /// Whether the project's `pubspec.yaml` depends on [package].
  bool _dependsOn(String package) {
    final pubspec = File(p.join(paths.root, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        RegExp(
          '^\\s+${RegExp.escape(package)}\\s*:',
          multiLine: true,
        ).hasMatch(pubspec.readAsStringSync());
  }

  /// The placeholders of the `job.model` stub for [models].
  Map<String, String> _jobModelValues(List<JobModelField> models) {
    final horizon = _dependsOn('daravel_horizon');
    final imports = <String>{
      "import 'package:daravel/daravel.dart';",
      if (horizon) "import 'package:daravel_horizon/daravel_horizon.dart';",
      for (final m in models)
        "import 'package:$_package/app/models/${Naming.snake(m.model)}.dart';",
    }.toList()..sort();
    return {
      'imports': imports.join('\n'),
      'params': [for (final m in models) 'required this.${m.field}'].join(', '),
      'fromJson': [
        for (final m in models)
          "    ${m.field}: ModelRef<${m.model}>(\n"
              "      () => ${m.model}.definition,\n"
              "      json['${m.field}']!,\n"
              '    ),',
      ].join('\n'),
      'fields': [
        for (final m in models)
          '  /// The [${m.model}], saved as its id and loaded fresh when the '
              'job runs.\n'
              '  final ModelRef<${m.model}> ${m.field};',
      ].join('\n\n'),
      'tags': [
        for (final m in models)
          horizon
              ? 'HorizonTags.model(${m.field})'
              : "'${m.model}:\${${m.field}.id}'",
      ].join(', '),
      'toJson': [
        for (final m in models) "    '${m.field}': ${m.field}.toJson(),",
      ].join('\n'),
      'dispatch': [
        for (final m in models)
          '${m.field}: ModelRef.of(${Naming.camel(m.model)})',
      ].join(', '),
      'resolve': [
        for (final m in models)
          '    // final ${Naming.camel(m.model)} = await ${m.field}.resolve();',
      ].join('\n'),
    };
  }

  /// A policy and its registry entry (`make:policy`).
  GeneratedFile policy(String name, {String? model}) {
    final className = Naming.withSuffix(name, 'Policy');
    final modelName = model == null ? null : Naming.pascal(model);
    final file = _render(
      p.join(paths.policies, '${Naming.snake(className)}.dart'),
      modelName == null ? 'policy' : 'policy.model',
      {
        'class': className,
        'model': modelName ?? '',
        'modelFile': modelName == null ? '' : Naming.snake(modelName),
        'package': _package,
      },
    );
    if (modelName != null) {
      _register(
        file,
        paths.policiesRegistry,
        RegistryPatcher.functionTemplate(
          header: '// Policy registry: model type → policy (Gate::policy).',
          signature: 'void registerPolicies(AuthorizationGate gate)',
        ),
        "import 'package:$_package/app/policies/${Naming.snake(className)}.dart';",
        '  gate.policy<$modelName>(const $className());',
        extraImport:
            "import 'package:$_package/app/models/${Naming.snake(modelName)}.dart';",
      );
    }
    return file;
  }

  /// A daravel_teorion query filter for [model] (from [name] without its
  /// `QueryFilter` suffix by default), registered in
  /// `bootstrap/query_filters.dart`.
  GeneratedFile queryFilter(String name, {String? model}) {
    final className = Naming.withSuffix(name, 'QueryFilter');
    final modelName = Naming.pascal(
      model ?? className.substring(0, className.length - 'QueryFilter'.length),
    );
    final file = _render(
      p.join(paths.queryFilters, '${Naming.snake(className)}.dart'),
      'query-filter',
      {
        'class': className,
        'model': modelName,
        'modelFile': Naming.snake(modelName),
        'package': _package,
      },
    );
    _register(
      file,
      paths.queryFiltersRegistry,
      RegistryPatcher.mapTemplate(
        header:
            '// Query filter registry (daravel_teorion): model type → its query\n'
            '// filter. Pass it to Application.configure(...).withQueryFilters().',
        mapType: 'Map<Type, QueryFilter<Model> Function()>',
        mapName: 'queryFilters',
        import:
            "import 'package:daravel/daravel.dart';\n"
            "import 'package:daravel_teorion/daravel_teorion.dart';",
      ),
      "import 'package:$_package/app/query_filters/${Naming.snake(className)}.dart';",
      '  $modelName: $className.new,',
      extraImport:
          "import 'package:$_package/app/models/${Naming.snake(modelName)}.dart';",
    );
    return file;
  }

  /// An event (`make:event`).
  GeneratedFile event(String name) {
    final className = Naming.pascal(name);
    return _render(
      p.join(paths.events, '${Naming.snake(className)}.dart'),
      'event',
      {'class': className},
    );
  }

  /// A listener and its registry entry (`make:listener`).
  GeneratedFile listener(String name, {String? event}) {
    final className = Naming.pascal(name);
    final eventName = event == null ? null : Naming.pascal(event);
    final file = _render(
      p.join(paths.listeners, '${Naming.snake(className)}.dart'),
      eventName == null ? 'listener' : 'listener.event',
      {
        'class': className,
        'event': eventName ?? '',
        'eventFile': eventName == null ? '' : Naming.snake(eventName),
        'package': _package,
      },
    );
    if (eventName != null) {
      _register(
        file,
        paths.listenersRegistry,
        RegistryPatcher.functionTemplate(
          header: r'// Listener registry: event → listeners (EventServiceProvider::$listen).',
          signature: 'void registerListeners(EventDispatcher events)',
        ),
        "import 'package:$_package/app/listeners/${Naming.snake(className)}.dart';",
        '  events.listen<$eventName>(const $className().handle);',
        extraImport:
            "import 'package:$_package/app/events/${Naming.snake(eventName)}.dart';",
      );
    }
    return file;
  }

  /// An API resource (`make:resource`).
  GeneratedFile resource(String name, {String? model}) {
    final className = Naming.withSuffix(name, 'Resource');
    final modelName = Naming.pascal(
      model ?? className.substring(0, className.length - 'Resource'.length),
    );
    final hasModel =
        model != null ||
        File(p.join(paths.models, '${Naming.snake(modelName)}.dart'))
            .existsSync();
    return _render(
      p.join(paths.resources, '${Naming.snake(className)}.dart'),
      hasModel ? 'resource.model' : 'resource',
      {
        'class': className,
        'model': modelName,
        'modelFile': Naming.snake(modelName),
        'package': _package,
      },
    );
  }

  /// A validation rule (`make:rule`).
  GeneratedFile rule(String name) {
    final className = Naming.pascal(name);
    return _render(
      p.join(paths.rules, '${Naming.snake(className)}.dart'),
      'rule',
      {'class': className, 'ruleName': Naming.snake(className)},
    );
  }

  /// `make:mail OrderShipped`: a [Mailable] in `lib/app/mail/`.
  GeneratedFile mail(String name) {
    final className = Naming.pascal(name);
    return _render(
      p.join(paths.mail, '${Naming.snake(className)}.dart'),
      'mail',
      {'class': className, 'subject': _headline(className)},
    );
  }

  /// `make:notification InvoicePaid`: a notification in
  /// `lib/app/notifications/`.
  GeneratedFile notification(String name) {
    final className = Naming.pascal(name);
    return _render(
      p.join(paths.notifications, '${Naming.snake(className)}.dart'),
      'notification',
      {'class': className},
    );
  }

  /// `OrderShipped` → `Order Shipped` (Laravel's `Str::headline`).
  static String _headline(String className) =>
      Naming.snake(className)
          .split('_')
          .where((w) => w.isNotEmpty)
          .map((w) => w[0].toUpperCase() + w.substring(1))
          .join(' ');

  /// A model observer (`make:observer`).
  GeneratedFile observer(String name, {required String model}) {
    final className = Naming.withSuffix(name, 'Observer');
    final modelName = Naming.pascal(model);
    hints.add(
      'Attach the observer: observers: [const $className()] in '
      '$modelName.definition.',
    );
    return _render(
      p.join(paths.observers, '${Naming.snake(className)}.dart'),
      'observer',
      {
        'class': className,
        'model': modelName,
        'modelFile': Naming.snake(modelName),
        'package': _package,
      },
    );
  }

  /// A service provider (`make:provider`).
  GeneratedFile provider(String name) {
    final className = Naming.withSuffix(name, 'ServiceProvider');
    hints.add(
      'Register it: .withProviders([const $className()]) in bootstrap/app.dart.',
    );
    return _render(
      p.join(paths.providers, '${Naming.snake(className)}.dart'),
      'provider',
      {'class': className},
    );
  }

  /// A console command and its registry entry (`make:command`).
  GeneratedFile command(String name, {String? signature}) {
    final className = Naming.withSuffix(name, 'Command');
    final base = className.substring(0, className.length - 'Command'.length);
    final file = _render(
      p.join(paths.commands, '${Naming.snake(className)}.dart'),
      'command',
      {
        'class': className,
        'signature': signature ?? 'app:${Naming.kebab(base)}',
      },
    );
    _register(
      file,
      paths.commandsRegistry,
      RegistryPatcher.template(
        header: '// Console command registry (custom dartisan commands).',
        listType: 'CommandFactory',
        listName: 'commands',
        import: "import 'package:dartisan_cli/dartisan_cli.dart';",
      ),
      "import 'package:$_package/app/console/commands/${Naming.snake(className)}.dart';",
      '  $className.new,',
    );
    return file;
  }

  /// A feature test, or a unit test when [unit] (`make:test`).
  GeneratedFile test(String name, {bool unit = false}) {
    final snake = Naming.snake(name.replaceAll(RegExp(r'_?[Tt]est$'), ''));
    return _render(
      p.join(unit ? paths.unitTests : paths.featureTests, '${snake}_test.dart'),
      unit ? 'test.unit' : 'test',
      {'description': snake.replaceAll('_', ' ')},
    );
  }

  /// Copies every built-in stub to `stubs/<name>.stub`.
  List<GeneratedFile> publishStubs() => [
    for (final entry in builtInStubs.entries)
      _write(p.join(paths.stubs, '${entry.key}.stub'), entry.value),
  ];

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  GeneratedFile _write(String path, String content) {
    final file = File(path);
    final exists = file.existsSync();
    if (exists && !force) {
      final result = GeneratedFile(path, skipped: true);
      log.add(result);
      return result;
    }
    if (!dryRun) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }
    final result = GeneratedFile(path, overwritten: exists);
    log.add(result);
    return result;
  }

  void _register(
    GeneratedFile file,
    String registry,
    String template,
    String importLine,
    String entryLine, {
    String? extraImport,
  }) {
    if (!updateRegistries || file.skipped) {
      return;
    }
    final target = File(registry);
    final existed = target.existsSync();
    var content = existed ? target.readAsStringSync() : template;
    var changed = false;
    for (final line in [?extraImport, importLine]) {
      final patched = RegistryPatcher.patch(
        content,
        importLine: line,
        entryLine: entryLine,
      );
      if (patched != null) {
        content = patched;
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    if (!dryRun) {
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(content);
    }
    log.add(GeneratedFile(registry, overwritten: existed));
  }
}
