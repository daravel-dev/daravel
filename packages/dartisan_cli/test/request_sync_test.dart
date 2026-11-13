import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:args/command_runner.dart';
import 'package:dartisan_cli/src/global_runner.dart';
import 'package:dartisan_cli/src/request_sync.dart';
import 'package:dartisan_cli/src/stubs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `request:sync` (W9.5): the typed input of a `FormRequest<Input>` is
/// written from its `Field` constants, like `model:sync` writes accessors.
void main() {
  String made([String name = 'StoreNoteRequest']) =>
      renderStub(builtInStubs['request']!, {'class': name});

  String withField(String source) => source.replaceFirst(
    "  static const name = Field<String>('name');",
    "  static const name = Field<String>('name');\n"
        "  static const stars = Field<int?>('stars');",
  );

  test('make:request writes what request:sync would write', () {
    final source = made();
    final request = RequestSource.parse(source)!;
    expect(request.className, 'StoreNoteRequest');
    expect(request.inputType, 'StoreNoteRequestInput');
    expect(request.fields, [(name: 'name', type: 'String', key: 'name')]);
    expect(syncRequestSource(source).source, source);
  });

  test('a new field gets its getter, in source order', () {
    final synced = syncRequestSource(withField(made())).source!;
    expect(
      synced,
      contains(
        '  String get name => _data.field(StoreNoteRequest.name);\n'
        '  int? get stars => _data.field(StoreNoteRequest.stars);\n',
      ),
    );
    expect(
      synced,
      contains(
        "  Map<String, Object?> get typed => {'name': name, 'stars': stars};\n"
        '}\n'
        '// </dartisan:input>',
      ),
    );
    // Synced again: unchanged.
    expect(syncRequestSource(synced).source, synced);
  });

  test('long names are laid out as dart format would', () async {
    const name = 'UpdateSubscriptionBillingAddressRequest';
    final source = made(name).replaceFirst(
      "  static const name = Field<String>('name');",
      "  static const name = Field<String>('name');\n"
          "  static const postalCode = Field<String?>('postal_code');\n"
          "  static const countryCode = Field<String?>('country_code');",
    );
    final synced = syncRequestSource(source).source!;
    expect(synced, contains('  String? get postalCode =>\n      _data.field('));
    expect(synced, contains('  Map<String, Object?> get typed => {\n'));
    expect(synced, contains("    'postal_code': postalCode,\n"));
    // dart format leaves the region as written, whatever the name length
    // (one-line, two-line and split extension type headers). The class
    // header above it is the stub's, not request:sync's.
    String region(String s) => s.substring(
      s.indexOf('// <dartisan:input>'),
      s.indexOf('// </dartisan:input>'),
    );
    final dir = Directory(p.normalize(p.absolute('.dart_tool/request_fmt')))
      ..createSync(recursive: true);
    final files = <File, String>{
      for (final (i, text) in [
        syncRequestSource(made('Note')).source!,
        made(),
        synced,
      ].indexed)
        File(p.join(dir.path, 'request_$i.dart'))..writeAsStringSync(text):
            text,
    };
    expect(region(files.values.first), contains('_data) implements'));
    expect(region(synced), contains('Input(\n  ValidatedData _data,\n)'));
    final format = await Process.run(Platform.resolvedExecutable, [
      'format',
      for (final file in files.keys) file.path,
    ]);
    expect(format.exitCode, 0, reason: '${format.stderr}');
    for (final MapEntry(key: file, value: text) in files.entries) {
      expect(region(file.readAsStringSync()), region(text), reason: file.path);
    }
  });

  test('a field named typed: no typed map, and a note', () {
    final sync = syncRequestSource(
      made().replaceFirst(
        "  static const name = Field<String>('name');",
        "  static const typed = Field<bool>('typed');",
      ),
    );
    expect(sync.source, contains('  bool get typed =>'));
    expect(sync.source, isNot(contains('Map<String, Object?> get typed')));
    expect(sync.note, contains('pass your own read:'));
  });

  test('a file without the region gets it appended at the end', () {
    final source = made().substring(0, made().indexOf('// <dartisan:input>'));
    final synced = syncRequestSource(source).source!;
    expect(synced, startsWith(source));
    expect(synced, endsWith('// </dartisan:input>\n'));
  });

  test('an input type written by hand, or an untyped request, is left', () {
    const handWritten = '''
final class R extends FormRequest<RInput> {
  static const a = Field<String>('a');
}

extension type const RInput(ValidatedData _d) implements ValidatedData {}
''';
    final hand = syncRequestSource(handWritten);
    expect(hand.source, isNull);
    expect(hand.note, contains('RInput is declared by hand'));
    const untyped = 'final class R extends FormRequest {}';
    expect(syncRequestSource(untyped).source, isNull);
    expect(RequestSource.parse(untyped), isNull);
  });

  group('the command', () {
    late Directory project;
    late File file;

    setUp(() {
      project = Directory.systemTemp.createTempSync('request_sync_');
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
      Directory(p.join(project.path, 'bootstrap')).createSync();
      final requests = Directory(
        p.join(project.path, 'lib', 'app', 'http', 'requests'),
      )..createSync(recursive: true);
      file = File(p.join(requests.path, 'store_note_request.dart'))
        ..writeAsStringSync(withField(made()));
      File(
        p.join(requests.path, 'legacy_request.dart'),
      ).writeAsStringSync('final class LegacyRequest extends FormRequest {}\n');
    });

    tearDown(() => project.deleteSync(recursive: true));

    // The project is this zone's working directory, never the process's:
    // `dart test` runs the test files as isolates of one process, and
    // setting the current directory there moves every other file's too.
    Future<int?> run(List<String> args) => IOOverrides.runZoned(
      () => (CommandRunner<int>(
        'dartisan',
        'test',
      )..addCommand(RequestSyncCommand())).run(['request:sync', ...args]),
      getCurrentDirectory: () => project,
    );

    test('--check exits 1 on a stale input and writes nothing', () async {
      final before = file.readAsStringSync();
      expect(await run(['--check']), 1);
      expect(file.readAsStringSync(), before);
    });

    test('sync writes the input, then --check passes', () async {
      expect(await run(['StoreNoteRequest']), 0);
      expect(file.readAsStringSync(), contains('int? get stars'));
      expect(await run(['--check']), 0);
    });

    test('a named request that is not the stale one checks clean', () async {
      expect(await run(['LegacyRequest', '--check']), 0);
    });

    test('the global dartisan writes the input while the project does not '
        'compile', () async {
      // The request names StoreNoteRequestInput, which no file declares,
      // and bin/dartisan.dart imports the application: every command of
      // the project CLI fails to compile. The global dartisan runs
      // request:sync in the project's own dartisan_cli instead, which
      // compiles no application code (here: in-process, as that run).
      final source = withField(made());
      final start = source.indexOf('// <dartisan:input>');
      final end = source.indexOf('// </dartisan:input>');
      file.writeAsStringSync(
        source.replaceRange(start, end + '// </dartisan:input>'.length, ''),
      );
      expect(
        file.readAsStringSync(),
        isNot(contains('extension type const StoreNoteRequestInput(')),
      );
      Directory(p.join(project.path, 'bin')).createSync();
      File(p.join(project.path, 'bin', 'dartisan.dart')).writeAsStringSync(
        "import '../bootstrap/app.dart';\nvoid main() => createApp();\n",
      );
      final runner = GlobalDartisanRunner();
      final inPackage = {GlobalDartisanRunner.inProjectPackage: '1'};
      Future<int> sync([List<String> args = const []]) => IOOverrides.runZoned(
        () => runner.execute(['request:sync', ...args], environment: inPackage),
        getCurrentDirectory: () => project,
      );
      expect(await sync(['--check']), 1);
      expect(await sync(), 0);
      expect(
        file.readAsStringSync(),
        allOf(
          contains('extension type const StoreNoteRequestInput('),
          contains('int? get stars'),
        ),
      );
      expect(await sync(['--check']), 0);
    });
  });

  test('the synced request compiles and types its input', () async {
    final synced = syncRequestSource(withField(made())).source!;
    final dir = Directory(
      p.normalize(p.absolute('.dart_tool/typed_api_request_sync')),
    );
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'request.dart')).writeAsStringSync(synced);
    File(p.join(dir.path, 'use.dart')).writeAsStringSync('''
import 'package:daravel/daravel.dart';

import 'request.dart';

Future<void> use(Request request) async {
  final StoreNoteRequestInput data = await const StoreNoteRequest()
      .validateRequest(request);
  final String name = data.name;
  final int? stars = data.stars;
  final Map<String, Object?> all = data.typed;
  print([name, stars, data.string('name'), all]);
}
''');
    final collection = AnalysisContextCollection(includedPaths: [dir.path]);
    final found = <String>[];
    for (final name in ['request.dart', 'use.dart']) {
      final path = p.join(dir.path, name);
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      if (result is ErrorsResult) {
        for (final d in result.diagnostics) {
          found.add(
            '$name:${result.lineInfo.getLocation(d.offset).lineNumber} '
            '${d.diagnosticCode.lowerCaseName}: ${d.message}',
          );
        }
      } else {
        found.add('$name: not analyzed');
      }
    }
    expect(found, isEmpty, reason: synced);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
