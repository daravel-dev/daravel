import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

void main() {
  group('version flag', () {
    test(
      'DartisanRunner accepts --version and prints Daravel Framework version',
      () async {
        final runner = DartisanRunner(
          () => throw UnimplementedError(
            'createApp should not be called for --version',
          ),
        );

        final output = <String>[];
        await IOOverrides.runZoned(
          () => runner.run(['--version']),
          stdout: () => _TestIOSink(output),
        );

        expect(output.join(), contains('Daravel Framework $daravelVersion'));
      },
    );

    test('DartisanRunner accepts -V abbr flag', () async {
      final runner = DartisanRunner(
        () => throw UnimplementedError('createApp should not be called for -V'),
      );

      final output = <String>[];
      await IOOverrides.runZoned(
        () => runner.run(['-V']),
        stdout: () => _TestIOSink(output),
      );

      expect(output.join(), contains('Daravel Framework $daravelVersion'));
    });

    test(
      'GlobalDartisanRunner accepts --version and prints Dartisan CLI version',
      () async {
        final runner = GlobalDartisanRunner();

        final output = <String>[];
        await IOOverrides.runZoned(
          () => runner.run(['--version']),
          stdout: () => _TestIOSink(output),
        );

        expect(output.join(), contains('Dartisan CLI $daravelVersion'));
      },
    );
  });
}

final class _TestIOSink implements Stdout {
  _TestIOSink(this.output);
  final List<String> output;

  @override
  void write(Object? obj) => output.add(obj.toString());

  @override
  void writeln([Object? obj = '']) => output.add('$obj\n');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
