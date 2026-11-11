@Tags(['typed-api'])
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The typed API of wave 9 (`User.cols.email`, ...) is only worth having if
/// a misspelt or mistyped use does not compile. Each snippet under
/// `test/typed_api/snippets/` starts with
///
/// ```dart
/// // expect: undefined_getter @7
/// ```
///
/// (one diagnostic, its code and its line in the snippet) or
/// `// expect: none`. The snippets are `.dart.snippet` files so the
/// workspace analysis (`dart analyze --fatal-infos`) never sees their
/// errors; this test copies them into `.dart_tool/typed_api_snippets/` of
/// this package, where `package:daravel` resolves, and analyzes them with
/// `package:analyzer`, no build step.
///
/// Codes are those of the `analyzer` package this test runs on, which can
/// differ from `dart analyze` in the SDK: analyzer 14.7 says
/// `undefined_instance_member_read` where the SDK says `undefined_getter`.
void main() {
  final source = Directory('test/typed_api/snippets');
  final target = Directory('.dart_tool/typed_api_snippets');

  setUpAll(() {
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    target.createSync(recursive: true);
    for (final file in source.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      final dart = name.endsWith('.dart.snippet')
          ? name.substring(0, name.length - '.snippet'.length)
          : name;
      file.copySync('${target.path}/$dart');
    }
  });

  test('every snippet gives exactly the diagnostic it expects', () async {
    final stopwatch = Stopwatch()..start();
    final collection = AnalysisContextCollection(
      includedPaths: [p.normalize(target.absolute.path)],
    );
    final files = target
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !_isSupport(f))
        .toList();
    expect(files, isNotEmpty);
    final problems = <String>[];
    for (final file in files) {
      final path = p.normalize(file.absolute.path);
      final expectation = _expectation(file.readAsStringSync());
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      if (result is! ErrorsResult) {
        problems.add('$path: not analyzed ($result)');
        continue;
      }
      final found = [
        for (final d in result.diagnostics)
          if (d.diagnosticCode.type.name != 'TODO')
            '${d.diagnosticCode.lowerCaseName} '
                '@${result.lineInfo.getLocation(d.offset).lineNumber}'
                ' (${d.message})',
      ];
      final name = file.uri.pathSegments.last;
      if (expectation == null) {
        if (found.isNotEmpty) {
          problems.add('$name: expected no diagnostic, got $found');
        }
      } else if (found.length != 1 || !found.single.startsWith(expectation)) {
        problems.add('$name: expected "$expectation", got $found');
      }
    }
    stopwatch.stop();
    // The PR reports this duration (Review #151 §3 A.8).
    stdout.writeln(
      'typed-api: ${files.length} snippets analyzed in '
      '${stopwatch.elapsedMilliseconds} ms',
    );
    expect(problems, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

bool _isSupport(File file) => file.uri.pathSegments.last.startsWith('_');

/// `undefined_getter @7` from the first line, or null for `none`.
String? _expectation(String snippet) {
  final first = snippet.split('\n').first.trim();
  final match = RegExp(r'^// expect: (.+)$').firstMatch(first);
  if (match == null) {
    throw StateError('A snippet must start with "// expect: ...": $first');
  }
  final value = match[1]!.trim();
  return value == 'none' ? null : value;
}
