import 'dart:io' as io;

import 'package:daravel/process.dart';
import 'package:test/test.dart';

/// The Dart VM is the one command every platform of the suite has.
final String dart = io.Platform.resolvedExecutable;

void main() {
  group('fake', () {
    test('stubs answer, with * as a wildcard, and the rest succeed', () async {
      await Process.fake((fake) async {
        final result = await Process.run(['git', 'status']);
        expect(result.output, 'clean');
        final other = await Process.run(['ls', '-la']);
        expect(other.successful, isTrue);
        expect(other.output, isEmpty);
        expect(fake.ran('git *'), 1);
        expect(fake.ran('rm *'), 0);
        expect(fake.recorded, hasLength(2));
      }, stubs: {'git *': const ProcessResultData(output: 'clean')});
    });

    test('a failing stub', () async {
      await Process.fake(
        (_) async {
          final result = await Process.run(['deploy']);
          expect(result.failed, isTrue);
          expect(result.throwIfFailed, throwsA(isA<ProcessFailedException>()));
        },
        stubs: {
          'deploy': const ProcessResultData(exitCode: 2, errorOutput: 'no'),
        },
      );
    });

    test('pipe hands the output on and stops at a failure', () async {
      await Process.fake(
        (fake) async {
          final result = await Process.pipe([
            ['one'],
            ['bad'],
            ['never'],
          ]);
          expect(result.exitCode, 1);
          expect(fake.ran('never'), 0);
        },
        stubs: {
          'one': const ProcessResultData(output: 'x'),
          'bad': const ProcessResultData(exitCode: 1),
        },
      );
    });

    test('pool keeps the order given', () async {
      await Process.fake(
        (_) async {
          final results = await Process.pool([
            ['a'],
            ['b'],
            ['c'],
          ], concurrency: 2);
          expect([for (final r in results) r.output], ['1', '2', '3']);
        },
        stubs: {
          'a': const ProcessResultData(output: '1'),
          'b': const ProcessResultData(output: '2'),
          'c': const ProcessResultData(output: '3'),
        },
      );
    });

    test('two fakes at once do not meet', () async {
      await Future.wait([
        Process.fake((fake) async {
          await Process.run(['one']);
          expect(fake.recorded, hasLength(1));
        }),
        Process.fake((fake) async {
          await Process.run(['two']);
          await Process.run(['three']);
          expect(fake.recorded, hasLength(2));
        }),
      ]);
    });
  });

  group('real processes', () {
    test('output, exit code and the error stream', () async {
      final result = await Process.run([dart, '--version']);
      expect(result.successful, isTrue);
      expect('${result.output}${result.errorOutput}', contains('Dart'));
    });

    test('a failing command', () async {
      final result = await Process.run([dart, 'no-such-file.dart']);
      expect(result.failed, isTrue);
      expect(result.throwIfFailed, throwsA(isA<ProcessFailedException>()));
    });

    test('a timeout kills it', () {
      final dir = io.Directory.systemTemp.createTempSync('daravel_process');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = io.File('${dir.path}/sleep.dart')
        ..writeAsStringSync(
          "void main() async { await Future<void>.delayed(const Duration(minutes: 1)); }",
        );
      expect(
        Process.run([dart, file.path], timeout: const Duration(seconds: 2)),
        throwsA(isA<ProcessTimedOutException>()),
      );
    });

    test('onOutput streams', () async {
      final chunks = <String>[];
      await Process.run([
        dart,
        '--version',
      ], onOutput: (_, chunk) => chunks.add(chunk));
      expect(chunks.join(), contains('Dart'));
    });
  });

  test('an empty command is refused', () {
    expect(Process.run(const []), throwsArgumentError);
  });
}
