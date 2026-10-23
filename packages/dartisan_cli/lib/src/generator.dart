import 'dart:io';

import 'package:path/path.dart' as p;

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

  String get models => p.join(root, 'lib', 'app', 'models');
  String get controllers => p.join(root, 'lib', 'app', 'http', 'controllers');
  String get requests => p.join(root, 'lib', 'app', 'http', 'requests');
  String get middleware => p.join(root, 'lib', 'app', 'http', 'middleware');
  String get migrations => p.join(root, 'database', 'migrations');
  String get seeders => p.join(root, 'database', 'seeders');
  String get factories => p.join(root, 'database', 'factories');
  String get migrationsRegistry => p.join(root, 'bootstrap', 'migrations.dart');
  String get seedersRegistry => p.join(root, 'bootstrap', 'seeders.dart');
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
      : '${overwritten ? 'overwrote' : 'created'} $path';
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
    return (
      start: start,
      end: end,
      lines: inner.split('\n').map((l) => l.trimRight()).toList(),
    );
  }

  static String _replaceRegion(
    String content,
    String open,
    String close,
    List<String> lines,
  ) {
    final region = _region(content, open, close);
    final body = lines.isEmpty ? '\n' : '\n${lines.join('\n')}\n';
    return content.substring(0, region.start + open.length) +
        body +
        content.substring(region.end);
  }

  /// A fresh registry file with markers.
  static String template({
    required String header,
    required String listType,
    required String listName,
  }) =>
      '''
$header
import 'package:daravel/daravel.dart';
$importsStart
$importsEnd

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<$listType> $listName = <$listType>[
$entriesStart
$entriesEnd
];
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

  // ---------------------------------------------------------------------------
  // Public generators
  // ---------------------------------------------------------------------------

  GeneratedFile model(String name, {String? table, bool softDeletes = false}) {
    final className = Naming.pascal(name);
    final tableName = table ?? Naming.table(className);
    return _write(
      p.join(paths.models, '${Naming.snake(className)}.dart'),
      Stubs.model(
        className: className,
        table: tableName,
        softDeletes: softDeletes,
      ),
    );
  }

  GeneratedFile migration(String name, {String? create, String? table}) {
    final snake = Naming.snake(name);
    final stamp = Naming.timestamp(_clock());
    final className = Naming.pascal(snake);
    final file = _write(
      p.join(paths.migrations, 'm_${stamp}_$snake.dart'),
      Stubs.migration(
        className: className,
        name: '${stamp}_$snake',
        create: create,
        table: table,
      ),
    );
    if (updateRegistries && !file.skipped) {
      _patchRegistry(
        paths.migrationsRegistry,
        template: RegistryPatcher.template(
          header:
              '// Migration registry (explicit, AOT-friendly). See BLUEPRINT_V2 ADR-002.',
          listType: 'Migration',
          listName: 'migrations',
        ),
        importLine: "import '../database/migrations/m_${stamp}_$snake.dart';",
        entryLine: '  const $className(),',
      );
    }
    return file;
  }

  GeneratedFile seeder(String name) {
    final className = Naming.pascal(name);
    final file = _write(
      p.join(paths.seeders, '${Naming.snake(className)}.dart'),
      Stubs.seeder(className: className),
    );
    if (updateRegistries && !file.skipped) {
      _patchRegistry(
        paths.seedersRegistry,
        template: RegistryPatcher.template(
          header:
              '// Seeder registry (explicit, AOT-friendly). The first entry is the root seeder.',
          listType: 'Seeder',
          listName: 'seeders',
        ),
        importLine:
            "import '../database/seeders/${Naming.snake(className)}.dart';",
        entryLine: '  const $className(),',
      );
    }
    return file;
  }

  GeneratedFile factory(String name, {String? model}) {
    final modelName = Naming.pascal(
      model ?? name.replaceAll(RegExp(r'Factory$'), ''),
    );
    return _write(
      p.join(paths.factories, '${Naming.snake(modelName)}_factory.dart'),
      Stubs.factory(modelName: modelName, packageName: paths.packageName),
    );
  }

  GeneratedFile controller(
    String name, {
    bool api = false,
    bool resource = false,
    String? model,
  }) {
    final className = Naming.pascal(
      name.endsWith('Controller') ? name : '${name}Controller',
    );
    return _write(
      p.join(paths.controllers, '${Naming.snake(className)}.dart'),
      Stubs.controller(
        className: className,
        api: api,
        resource: resource || api,
        model: model == null ? null : Naming.pascal(model),
        packageName: paths.packageName,
      ),
    );
  }

  GeneratedFile request(String name) {
    final className = Naming.pascal(
      name.endsWith('Request') ? name : '${name}Request',
    );
    return _write(
      p.join(paths.requests, '${Naming.snake(className)}.dart'),
      Stubs.request(className: className),
    );
  }

  GeneratedFile middleware(String name) {
    final className = Naming.pascal(
      name.endsWith('Middleware') ? name : '${name}Middleware',
    );
    return _write(
      p.join(paths.middleware, '${Naming.snake(className)}.dart'),
      Stubs.middleware(className: className),
    );
  }

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

  void _patchRegistry(
    String path, {
    required String template,
    required String importLine,
    required String entryLine,
  }) {
    final file = File(path);
    final content = file.existsSync() ? file.readAsStringSync() : template;
    final patched = RegistryPatcher.patch(
      content,
      importLine: importLine,
      entryLine: entryLine,
    );
    if (patched == null) {
      return;
    }
    if (!dryRun) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(patched);
    }
    log.add(GeneratedFile(path, overwritten: file.existsSync()));
  }
}

/// Code templates (publishable later via `stub:publish`).
abstract final class Stubs {
  static String model({
    required String className,
    required String table,
    bool softDeletes = false,
  }) =>
      '''
import 'package:daravel/daravel.dart';

final class $className extends Model {
  static final ModelDefinition<$className> definition = ModelDefinition<$className>(
    table: '$table',
    factory: $className.new,
    fillable: [],
    hidden: [],
    casts: {
      'created_at': Cast.dateTime,
      'updated_at': Cast.dateTime,
    },${softDeletes ? '\n    softDeletes: true,' : ''}
    relations: {},
  );

  @override
  ModelDefinition<$className> get modelDefinition => $className.definition;

  // <dartisan:statics>
  static ModelQuery<$className> query() => definition.query();
  static Future<$className?> find(Object id) => query().find(id);
  static Future<$className> findOrFail(Object id) => query().findOrFail(id);
  static Future<$className> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<$className>> all() => query().get();
  static ModelQuery<$className> where(Object column, [Object? op, Object? value]) =>
      query().where(column, op, value);
  // </dartisan:statics>

  // <dartisan:accessors>
  int get id => getAttr('id');
  DateTime? get createdAt => getAttr('created_at');
  DateTime? get updatedAt => getAttr('updated_at');
  // </dartisan:accessors>
}
''';

  static String migration({
    required String className,
    required String name,
    String? create,
    String? table,
  }) {
    final String up;
    final String down;
    if (create != null) {
      up =
          '''
    await schema.create('$create', (table) {
      table.id();
      table.timestamps();
    });''';
      down = "    await schema.dropIfExists('$create');";
    } else if (table != null) {
      up =
          '''
    await schema.table('$table', (table) {
      // table.string('column').nullable();
    });''';
      down =
          '''
    await schema.table('$table', (table) {
      // table.dropColumn('column');
    });''';
    } else {
      up = '    // Schema changes go here.';
      down = '    // Reverse the changes made in up().';
    }
    return '''
import 'package:daravel/daravel.dart';

final class $className extends Migration {
  const $className();

  @override
  String get name => '$name';

  @override
  Future<void> up(SchemaBuilder schema) async {
$up
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
$down
  }
}
''';
  }

  static String seeder({required String className}) =>
      '''
import 'package:daravel/daravel.dart';

final class $className extends Seeder {
  const $className();

  @override
  Future<void> run() async {
    // Seed the database here, e.g. await userFactory().createMany(const {}, 10);
  }
}
''';

  static String factory({
    required String modelName,
    required String packageName,
  }) =>
      '''
import 'package:daravel/daravel.dart';
import 'package:$packageName/app/models/${Naming.snake(modelName)}.dart';

/// Factory for [$modelName].
ModelFactory<$modelName> ${Naming.camel(modelName)}Factory({Faker? faker}) => ModelFactory<$modelName>(
  $modelName.definition,
  (Faker f) => <String, Object?>{
    // 'name': f.name(),
  },
  faker: faker,
);
''';

  static String controller({
    required String className,
    required bool api,
    required bool resource,
    required String packageName,
    String? model,
  }) {
    final modelImport = model == null
        ? ''
        : "import 'package:$packageName/app/models/${Naming.snake(model)}.dart';\n";
    final implementsClause = resource ? ' implements ResourceController' : '';
    final body = resource
        ? '''
  @override
  Future<Object?> index(Request request) async => ${model == null ? '<String, Object?>{}' : '$model.query().paginate()'};

  @override
  Future<Object?> store(Request request) async {
    final data = await request.validate({});
    return Response.created(data.toMap());
  }

  @override
  Future<Object?> show(Request request) async => ${model == null ? '<String, Object?>{}' : "$model.findOrFail(request.param<int>('${Naming.snake(model)}'))"};

  @override
  Future<Object?> update(Request request) async {
    final data = await request.validate({});
    return data.toMap();
  }

  @override
  Future<Object?> destroy(Request request) async => Response.noContent();
'''
        : '''
  Future<Object?> index(Request request) async => <String, Object?>{};
''';
    return '''
import 'package:daravel/daravel.dart';
$modelImport
final class $className$implementsClause {
$body}
''';
  }

  static String request({required String className}) =>
      '''
import 'package:daravel/daravel.dart';

final class $className extends FormRequest {
  const $className();

  @override
  FutureOr<bool> authorize(Request request) => true;

  @override
  Map<String, Object> rules(Request request) => {
    // 'email': 'required|email',
  };
}
''';

  static String middleware({required String className}) =>
      '''
import 'package:daravel/daravel.dart';

final class $className implements Middleware {
  const $className();

  @override
  Future<Response> handle(Request request, Next next) async {
    final response = await next(request);
    return response;
  }
}
''';
}
