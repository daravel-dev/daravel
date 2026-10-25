import 'dart:io';

import 'package:path/path.dart' as p;

import 'stubs.dart';

/// Locates a Daravel project (BLUEPRINT_V2 §8.3): a directory with a
/// `pubspec.yaml` and a `bootstrap/` folder.
final class ProjectPaths {
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

  final String root;
  final String packageName;

  String _app(List<String> parts) => p.joinAll([root, 'lib', 'app', ...parts]);

  String get models => _app(['models']);
  String get controllers => _app(['http', 'controllers']);
  String get requests => _app(['http', 'requests']);
  String get middleware => _app(['http', 'middleware']);
  String get resources => _app(['http', 'resources']);
  String get jobs => _app(['jobs']);
  String get events => _app(['events']);
  String get listeners => _app(['listeners']);
  String get policies => _app(['policies']);
  String get rules => _app(['rules']);
  String get observers => _app(['observers']);
  String get providers => _app(['providers']);
  String get commands => _app(['console', 'commands']);
  String get migrations => p.join(root, 'database', 'migrations');
  String get seeders => p.join(root, 'database', 'seeders');
  String get factories => p.join(root, 'database', 'factories');
  String get featureTests => p.join(root, 'test', 'feature');
  String get unitTests => p.join(root, 'test', 'unit');
  String get stubs => p.join(root, 'stubs');
  String get migrationsRegistry => p.join(root, 'bootstrap', 'migrations.dart');
  String get seedersRegistry => p.join(root, 'bootstrap', 'seeders.dart');
  String get jobsRegistry => p.join(root, 'bootstrap', 'jobs.dart');
  String get modelsRegistry => p.join(root, 'bootstrap', 'models.dart');
  String get policiesRegistry => p.join(root, 'bootstrap', 'policies.dart');
  String get listenersRegistry => p.join(root, 'bootstrap', 'listeners.dart');
  String get commandsRegistry => p.join(root, 'bootstrap', 'commands.dart');
}

/// Naming helpers shared by generators.
abstract final class Naming {
  static String pascal(String input) => input
      .split(RegExp(r'[^A-Za-z0-9]+|(?<=[a-z0-9])(?=[A-Z])'))
      .where((s) => s.isNotEmpty)
      .map((s) => s[0].toUpperCase() + s.substring(1))
      .join();

  static String snake(String input) => input
      .replaceAllMapped(RegExp(r'(?<=[a-z0-9])([A-Z])'), (m) => '_${m[1]}')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '')
      .toLowerCase();

  static String kebab(String input) => snake(input).replaceAll('_', '-');

  static String camel(String input) {
    final pascalCase = pascal(input);
    return pascalCase.isEmpty
        ? ''
        : pascalCase[0].toLowerCase() + pascalCase.substring(1);
  }

  /// `User` → `users`, `Category` → `categories`, `Address` → `addresses`.
  static String plural(String word) {
    if (word.endsWith('y') && !RegExp(r'[aeiou]y$').hasMatch(word)) {
      return '${word.substring(0, word.length - 1)}ies';
    }
    if (RegExp(r'(s|x|z|ch|sh)$').hasMatch(word)) {
      return '${word}es';
    }
    return '${word}s';
  }

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
  const GeneratedFile(
    this.path, {
    this.overwritten = false,
    this.skipped = false,
  });

  final String path;
  final bool overwritten;
  final bool skipped;

  @override
  String toString() => skipped
      ? 'skipped $path'
      : '${overwritten ? 'updated' : 'created'} $path';
}

/// Inserts import and entry lines into registry files that carry
/// `// <dartisan:imports>` and `// <dartisan:entries>` regions (ADR-002).
/// Idempotent: existing lines are not duplicated; imports stay sorted.
abstract final class RegistryPatcher {
  static const String importsStart = '// <dartisan:imports>';
  static const String importsEnd = '// </dartisan:imports>';
  static const String entriesStart = '// <dartisan:entries>';
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
  Generator(
    this.paths, {
    this.force = false,
    this.dryRun = false,
    this.updateRegistries = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ProjectPaths paths;
  final bool force;
  final bool dryRun;
  final bool updateRegistries;
  final DateTime Function() _clock;
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
    return file;
  }

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

  GeneratedFile request(String name) {
    final className = Naming.withSuffix(name, 'Request');
    return _render(
      p.join(paths.requests, '${Naming.snake(className)}.dart'),
      'request',
      {'class': className},
    );
  }

  GeneratedFile middleware(String name) {
    final className = Naming.withSuffix(name, 'Middleware');
    return _render(
      p.join(paths.middleware, '${Naming.snake(className)}.dart'),
      'middleware',
      {'class': className},
    );
  }

  GeneratedFile job(String name) {
    final className = Naming.pascal(name);
    final file = _render(
      p.join(paths.jobs, '${Naming.snake(className)}.dart'),
      'job',
      {'class': className, 'jobName': Naming.kebab(className)},
    );
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

  GeneratedFile event(String name) {
    final className = Naming.pascal(name);
    return _render(
      p.join(paths.events, '${Naming.snake(className)}.dart'),
      'event',
      {'class': className},
    );
  }

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

  GeneratedFile rule(String name) {
    final className = Naming.pascal(name);
    return _render(
      p.join(paths.rules, '${Naming.snake(className)}.dart'),
      'rule',
      {'class': className, 'ruleName': Naming.snake(className)},
    );
  }

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
