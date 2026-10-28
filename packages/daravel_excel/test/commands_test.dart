import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_excel/commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;
  late String previous;

  setUp(() {
    project = Directory.systemTemp.createTempSync('daravel_excel_make_');
    File(p.join(project.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\n');
    Directory(p.join(project.path, 'bootstrap')).createSync();
    previous = Directory.current.path;
    Directory.current = project;
  });

  tearDown(() {
    Directory.current = previous;
    project.deleteSync(recursive: true);
  });

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('dartisan', 'test');
    for (final factory in excelCommands) {
      runner.addCommand(factory(() => throw UnimplementedError()));
    }
    return runner.run(args);
  }

  String read(String path) =>
      File(p.join(project.path, 'lib', 'app', path)).readAsStringSync();

  test('make:export and make:import, with and without a model', () async {
    expect(await run(['make:export', 'StudentsExport', '--model=student']), 0);
    expect(await run(['make:import', 'students_import', '--model=Student']), 0);
    expect(await run(['make:export', 'Totals']), 0);
    expect(await run(['make:import', 'Rows']), 0);
    expect(await run(['make:export', 'Totals']), 1, reason: 'exists');
    expect(await run(['make:export', 'Totals', '--force']), 0);

    final export = read('exports/students_export.dart');
    expect(export, contains('final class StudentsExport implements FromQuery'));
    expect(export, contains("import 'package:demo/app/models/student.dart';"));
    expect(export, contains('Student.definition.query()'));
    expect(
      read('imports/students_import.dart'),
      contains('implements ToModel, WithValidation'),
    );
    expect(
      read('exports/totals.dart'),
      contains('implements FromCollection, WithHeadings'),
    );
    expect(read('imports/rows.dart'), contains('implements ToCollection'));
  });

  test('the generated classes pass strict analysis', () async {
    // Generated against `demo`'s model, analyzed against the test model.
    await run(['make:export', 'StudentsExport', '--model=Student']);
    await run(['make:import', 'StudentsImport', '--model=Student']);
    await run(['make:export', 'Totals']);
    await run(['make:import', 'Rows']);
    final out = Directory(p.join(previous, 'test', '_generated'))..createSync();
    addTearDown(() => out.deleteSync(recursive: true));
    for (final path in [
      'exports/students_export.dart',
      'imports/students_import.dart',
      'exports/totals.dart',
      'imports/rows.dart',
    ]) {
      File(p.join(out.path, p.basename(path))).writeAsStringSync(
        read(path).replaceAll(
          "import 'package:demo/app/models/student.dart';",
          "import '../excel_test.dart';",
        ),
      );
    }
    final result = await Process.run(Platform.resolvedExecutable, [
      'analyze',
      '--fatal-infos',
      out.path,
    ], workingDirectory: previous);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    // Keep the import of package:daravel used by the model template.
    expect(Model, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
