import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import '../foundation/exceptions.dart';

enum ProcessOutputType { stdout, stderr }

/// A finished command (`Illuminate\Process\ProcessResult`).
final class ProcessResultData {
  const ProcessResultData({
    this.command = const <String>[],
    this.exitCode = 0,
    this.output = '',
    this.errorOutput = '',
  });

  final List<String> command;
  final int exitCode;
  final String output;
  final String errorOutput;

  bool get successful => exitCode == 0;
  bool get failed => !successful;

  bool seeInOutput(String text) => output.contains(text);
  bool seeInErrorOutput(String text) => errorOutput.contains(text);

  /// This result, or a [ProcessFailedException] when the command failed.
  ProcessResultData throwIfFailed() {
    if (failed) {
      throw ProcessFailedException(this);
    }
    return this;
  }
}

final class ProcessFailedException extends DaravelException {
  ProcessFailedException(this.result)
    : super(
        'The command "${result.command.join(' ')}" failed with exit code '
        '${result.exitCode}.',
      );

  final ProcessResultData result;
}

final class ProcessTimedOutException extends DaravelException {
  ProcessTimedOutException(this.command, this.timeout)
    : super(
        'The command "${command.join(' ')}" exceeded the timeout of '
        '${timeout.inSeconds} seconds.',
      );

  final List<String> command;
  final Duration timeout;
}

/// Answers commands inside [Process.fake], and records them.
final class ProcessFake {
  ProcessFake(this._stubs);

  final Map<String, ProcessResultData> _stubs;

  /// Each command run, in order.
  final List<List<String>> recorded = <List<String>>[];

  static RegExp _pattern(String pattern) =>
      RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$');

  ProcessResultData _answer(List<String> command) {
    recorded.add(command);
    final line = command.join(' ');
    for (final MapEntry(:key, :value) in _stubs.entries) {
      if (_pattern(key).hasMatch(line)) {
        return ProcessResultData(
          command: command,
          exitCode: value.exitCode,
          output: value.output,
          errorOutput: value.errorOutput,
        );
      }
    }
    return ProcessResultData(command: command);
  }

  /// How many recorded commands match [pattern], where `*` is anything.
  int ran(String pattern) {
    final matcher = _pattern(pattern);
    return recorded.where((c) => matcher.hasMatch(c.join(' '))).length;
  }
}

/// `Process::run()`, `pipe()`, `pool()` and `fake()`.
///
/// Import `package:daravel/process.dart` for it: the full barrel leaves it
/// out, or every file that also uses `dart:io`'s `Process` would stop
/// compiling.
abstract final class Process {
  static final Object _fakeKey = Object();

  static ProcessFake? get _fake => Zone.current[_fakeKey] as ProcessFake?;

  /// Runs [command] with no shell, so its arguments need no escaping.
  /// [timeout] kills it and throws a [ProcessTimedOutException].
  static Future<ProcessResultData> run(
    List<String> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout = const Duration(seconds: 60),
    String? input,
    void Function(ProcessOutputType type, String chunk)? onOutput,
  }) async {
    final fake = _fake;
    if (fake != null) {
      return fake._answer(command);
    }
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'Empty command');
    }
    final process = await io.Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final output = StringBuffer();
    final errorOutput = StringBuffer();
    Future<void> collect(
      Stream<List<int>> stream,
      StringBuffer buffer,
      ProcessOutputType type,
    ) => stream.transform(utf8.decoder).forEach((chunk) {
      buffer.write(chunk);
      onOutput?.call(type, chunk);
    });
    final reading = Future.wait([
      collect(process.stdout, output, ProcessOutputType.stdout),
      collect(process.stderr, errorOutput, ProcessOutputType.stderr),
    ]);
    if (input != null) {
      process.stdin.write(input);
    }
    await process.stdin.close();
    final int exitCode;
    try {
      exitCode = timeout == null
          ? await process.exitCode
          : await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(io.ProcessSignal.sigkill);
      throw ProcessTimedOutException(command, timeout!);
    }
    await reading;
    return ProcessResultData(
      command: command,
      exitCode: exitCode,
      output: output.toString(),
      errorOutput: errorOutput.toString(),
    );
  }

  /// Runs the commands one after another, each reading the output of the
  /// one before. It stops at the first failure and answers that result.
  static Future<ProcessResultData> pipe(
    List<List<String>> commands, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout = const Duration(seconds: 60),
  }) async {
    if (commands.isEmpty) {
      throw ArgumentError.value(commands, 'commands', 'Empty pipe');
    }
    ProcessResultData? previous;
    for (final command in commands) {
      previous = await run(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout,
        input: previous?.output,
      );
      if (previous.failed) {
        break;
      }
    }
    return previous!;
  }

  /// Runs [commands] at the same time, at most [concurrency] of them, and
  /// answers their results in the order given.
  static Future<List<ProcessResultData>> pool(
    List<List<String>> commands, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout = const Duration(seconds: 60),
    int concurrency = 4,
  }) async {
    final results = List<ProcessResultData?>.filled(commands.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < commands.length) {
        final index = next++;
        results[index] = await run(
          commands[index],
          workingDirectory: workingDirectory,
          environment: environment,
          timeout: timeout,
        );
      }
    }

    final workers = concurrency < commands.length
        ? concurrency
        : commands.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return results.cast<ProcessResultData>();
  }

  /// Runs [body] with no real processes: [stubs] answer commands that match,
  /// where `*` is anything, and the others succeed with no output. It lives
  /// in the zone, so parallel tests do not see each other's.
  static Future<T> fake<T>(
    Future<T> Function(ProcessFake fake) body, {
    Map<String, ProcessResultData> stubs = const {},
  }) {
    final fake = ProcessFake(stubs);
    return runZoned(() => body(fake), zoneValues: {_fakeKey: fake});
  }
}
