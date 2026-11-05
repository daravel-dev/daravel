import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A class declaration that names [CoordinatorMessage] among its
/// supertypes, with the annotations and modifiers before it.
final RegExp _messageClass = RegExp(
  r'^((?:[ \t]*@[^\n]*\n)*)[ \t]*((?:\w+[ \t]+)*)class[ \t]+(\w+)'
  r'[^{;]*\bCoordinatorMessage\b[^{;]*\{',
  multiLine: true,
);

/// The classes of [source] that are coordinator messages, each with what
/// is wrong with it (empty when nothing is). Pragmas cannot be read by
/// reflection, hence a source check, like `architecture_test.dart`.
Map<String, List<String>> checkMessages(String source) {
  final found = <String, List<String>>{};
  for (final match in _messageClass.allMatches(source)) {
    final name = match.group(3)!;
    final modifiers = match.group(2)!.split(RegExp(r'\s+'));
    if (name == 'CoordinatorMessage') {
      continue;
    }
    found[name] = [
      if (!match.group(1)!.contains("@pragma('vm:deeply-immutable')"))
        "is not annotated @pragma('vm:deeply-immutable')",
      if (!modifiers.contains('final')) 'is not final',
    ];
  }
  return found;
}

/// Hosts a coordinator with [_EchoService] in its own isolate and sends
/// its port to [ready].
void _hostCoordinator(SendPort ready) {
  final coordinator = Coordinator()..register(_EchoService());
  ready.send(coordinator.listen());
}

/// Answers a batch of messages with the batch itself.
final class _EchoService implements TypedCoordinatorService<List<Object?>> {
  @override
  String get name => 'echo';

  @override
  Object? handle(String op, Map<String, Object?> args) => null;

  @override
  Object? handleTyped(List<Object?> message) => message;

  @override
  Map<String, Object?> stats() => const {};
}

void main() {
  test('the source check flags a message class without the pragma', () {
    const source = '''
/// Fine.
@pragma('vm:deeply-immutable')
final class Good implements CoordinatorMessage {
  const Good();
}

@immutable
final class Bare implements Object, CoordinatorMessage {}

@pragma('vm:deeply-immutable')
base class Open implements CoordinatorMessage {}

abstract interface class CoordinatorMessage {}

final class Unrelated {}
''';
    expect(checkMessages(source), {
      'Good': isEmpty,
      'Bare': ["is not annotated @pragma('vm:deeply-immutable')"],
      'Open': ['is not final'],
    });
  });

  test('every CoordinatorMessage in lib/src is a final deeply-immutable '
      'class', () {
    final problems = <String>[];
    final messages = <String>[];
    final files =
        Directory('lib/src')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final source = file.readAsStringSync().replaceAll('\r\n', '\n');
      for (final MapEntry(key: name, value: issues) in checkMessages(
        source,
      ).entries) {
        messages.add(name);
        final where = p.relative(file.path, from: 'lib/src');
        problems.addAll(issues.map((issue) => '$name ($where) $issue'));
      }
    }
    expect(problems, isEmpty);
    // The scan must find the framework's messages, or it checks nothing.
    expect(
      messages,
      containsAll(<String>[
        'RateLimitMessage',
        'LockMessage',
        'RateLimitGrant',
      ]),
    );
  });

  test('10 000 messages cross a RemoteCoordinatorChannel and come back '
      'intact and shared', () async {
    final ready = Completer<SendPort>();
    final handshake = RawReceivePort(
      (Object? port) => ready.complete(port! as SendPort),
    );
    final host = await Isolate.spawn(_hostCoordinator, handshake.sendPort);
    addTearDown(() => host.kill(priority: Isolate.immediate));
    final port = await ready.future;
    handshake.close();
    final channel = RemoteCoordinatorChannel(port);
    addTearDown(channel.close);

    final batch = <CoordinatorMessage>[
      for (var i = 0; i < 10000; i++)
        i.isEven
            ? RateLimitMessage('attempt', 'key-$i', max: i, decayMs: 60000)
            : LockMessage('acquireLock', 'lock-$i', owner: 'w$i', ttlMs: i),
    ];
    final reply = await channel.callTyped(
      'echo',
      batch,
      timeout: const Duration(seconds: 30),
    );

    expect(reply, isA<List<Object?>>());
    final back = reply! as List<Object?>;
    expect(back, hasLength(10000));
    expect(identical(back, batch), isFalse, reason: 'the list is copied');
    for (var i = 0; i < back.length; i++) {
      final message = back[i];
      if (i.isEven) {
        message as RateLimitMessage;
        expect(
          [message.op, message.key, message.max, message.decayMs],
          ['attempt', 'key-$i', i, 60000],
        );
      } else {
        message as LockMessage;
        expect(
          [message.op, message.key, message.owner, message.ttlMs],
          ['acquireLock', 'lock-$i', 'w$i', i],
        );
      }
      // Deeply immutable: shared with the other isolate, not copied. This
      // fails if the VM stops honouring the pragma.
      expect(identical(message, batch[i]), isTrue, reason: 'message $i');
    }
  });
}
