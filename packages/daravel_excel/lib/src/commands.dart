import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;

/// The `make:export` and `make:import` commands, for
/// `bootstrap/commands.dart`.
const List<CommandFactory> excelCommands = [
  MakeExportCommand.new,
  MakeImportCommand.new,
];

abstract base class _MakeExcelCommand extends Command<int> {
  _MakeExcelCommand() {
    argParser
      ..addOption('model', help: 'The model the class reads or creates.')
      ..addFlag('force', negatable: false, help: 'Overwrite the file.');
  }

  String get folder;
  String source(String className, String package, String? model);

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Missing <name> argument.');
    }
    final paths = ProjectPaths.locate();
    final className = Naming.pascal(rest.first);
    final file = File(
      p.join(
        paths.root,
        'lib',
        'app',
        folder,
        '${Naming.snake(className)}.dart',
      ),
    );
    if (file.existsSync() && !(argResults!['force'] as bool)) {
      stderr.writeln(
        '${p.relative(file.path, from: paths.root)} exists; pass --force.',
      );
      return 1;
    }
    final model = argResults!['model'] as String?;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      source(
        className,
        paths.packageName,
        model == null ? null : Naming.pascal(model),
      ),
    );
    stdout.writeln('Created ${p.relative(file.path, from: paths.root)}');
    return 0;
  }
}

/// `make:export <Name> [--model=Student]`.
final class MakeExportCommand extends _MakeExcelCommand {
  MakeExportCommand(AppFactory _);

  @override
  String get name => 'make:export';

  @override
  String get description => 'Create an export class (daravel_excel).';

  @override
  String get folder => 'exports';

  @override
  String source(String className, String package, String? model) =>
      model == null
      ? '''
import 'package:daravel_excel/daravel_excel.dart';

final class $className implements FromCollection, WithHeadings {
  @override
  List<Object?> headings() => ['Column'];

  @override
  Iterable<Object?> collection() => [
    ['value'],
  ];
}
'''
      : '''
import 'package:daravel_excel/daravel_excel.dart';
import 'package:$package/app/models/${Naming.snake(model)}.dart';

final class $className implements FromQuery, WithHeadings, WithMapping {
  @override
  Object query() => $model.definition.query();

  @override
  List<Object?> headings() => ['ID', 'Created at'];

  @override
  List<Object?> map(Object? row) {
    final model = row! as $model;
    return [model.key, model['created_at']];
  }
}
''';
}

/// `make:import <Name> [--model=Student]`.
final class MakeImportCommand extends _MakeExcelCommand {
  MakeImportCommand(AppFactory _);

  @override
  String get name => 'make:import';

  @override
  String get description => 'Create an import class (daravel_excel).';

  @override
  String get folder => 'imports';

  @override
  String source(String className, String package, String? model) =>
      model == null
      ? '''
import 'package:daravel_excel/daravel_excel.dart';

final class $className with WithHeadingRow implements ToCollection {
  /// Every row, keyed by its heading: `rows.first['column_heading']`.
  @override
  Future<void> collection(List<Map<String, Object?>> rows) async {}
}
'''
      : '''
import 'package:daravel/daravel.dart';
import 'package:daravel_excel/daravel_excel.dart';
import 'package:$package/app/models/${Naming.snake(model)}.dart';

final class $className with WithHeadingRow implements ToModel, WithValidation {
  @override
  Model? model(Map<String, Object?> row) =>
      $model.definition.newInstance({'name': row['name']});

  @override
  Map<String, Object> rules() => {'name': 'required'};
}
''';
}
