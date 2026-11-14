import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// HC-1 (Reviewer RSEQ 53 #8, #9): a value whose `toString()` throws (an
/// ordinary object in the context, the result of `toLogValue()`, the
/// record's error) cost the whole record in the JSON handlers; the
/// console wrote the channel name without escaping it.
void main() {
  final cases = <String, LogRecord Function()>{
    'context value': () => LogRecord(
      time: DateTime.utc(2026),
      level: LogLevel.error,
      message: 'ctx',
      channel: 'app',
      context: {'bad': _Throwing()},
    ),
    'toLogValue result': () => LogRecord(
      time: DateTime.utc(2026),
      level: LogLevel.error,
      message: 'loggable',
      channel: 'app',
      context: Logger(handlers: const []).redact({'v': _ReturnsThrowing()}),
    ),
    'error': () => LogRecord(
      time: DateTime.utc(2026),
      level: LogLevel.error,
      message: 'err',
      channel: 'app',
      context: const {},
      error: _Throwing(),
    ),
  };

  for (final MapEntry(key: place, value: record) in cases.entries) {
    test('$place: the console writes the record', () {
      final err = StringBuffer();
      ConsoleHandler(out: StringBuffer(), err: err).handle(record());
      expect(err.toString(), contains('[UNLOGGABLE: _Throwing]'));
    });

    test('$place: JsonHandler writes the record', () {
      final out = StringBuffer();
      JsonHandler(out).handle(record());
      expect(out.toString(), contains('[UNLOGGABLE: _Throwing]'));
    });

    test('$place: DailyFileHandler writes the record', () async {
      final dir = Directory.systemTemp.createTempSync('daravel_unloggable');
      addTearDown(() => dir.deleteSync(recursive: true));
      final handler = DailyFileHandler(dir.path);
      final written = record();
      handler.handle(written);
      await handler.close();
      final text = File(handler.pathFor(written.time)).readAsStringSync();
      expect(text, contains('[UNLOGGABLE: _Throwing]'));
    });
  }

  test('the console escapes the channel name', () {
    final out = StringBuffer();
    ConsoleHandler(out: out, err: StringBuffer(), showChannel: true).handle(
      LogRecord(
        time: DateTime.utc(2026),
        level: LogLevel.info,
        message: 'm',
        channel: 'app\nforged',
        context: const {},
      ),
    );
    expect(out.toString().trimRight().split('\n'), hasLength(1));
    expect(out.toString(), contains(r'app\nforged'));
  });
}

final class _Throwing {
  @override
  String toString() => throw StateError('no');
}

final class _ReturnsThrowing implements Loggable {
  @override
  Object? toLogValue() => _Throwing();
}
