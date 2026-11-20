import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A chunked body that goes over `maxBodyBytes` is refused while it is
/// read: the read fails with a `413`, and the rest of the body is left to
/// the server, which answers and then closes the connection. Whatever
/// then happens to that rest (the server releases it after a streamed
/// answer, the answer fails to write, the client goes away or ends its
/// body midway), nothing reaches the closed read: no uncaught error in
/// the request's zone, and the request is not in flight any more.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler logs;

  Future<void> serve({required String answer}) async {
    logs = MemoryHandler();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) => router.post('/bytes', (request) async {
            try {
              final data = await request.bytes();
              return Response.text('ok:${data.length}');
            } on PayloadTooLargeHttpException {
              if (answer == 'failing-stream') {
                return Response.stream(
                  Stream<List<int>>.error(StateError('write fails')),
                  status: 413,
                  contentType: 'text/plain',
                );
              }
              return Response.stream(
                Stream<List<int>>.fromIterable([utf8.encode('too large')]),
                status: 413,
                contentType: 'text/plain',
              );
            }
          }),
        )
        .create();
    await app.boot();
    engine = ServerEngine(
      app,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        maxBodyBytes: 1024,
        shutdownTimeout: Duration(milliseconds: 500),
      ),
      kernel: app.kernel,
      logger: Logger(handlers: [logs]),
    );
    await engine.start();
  }

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
  });

  /// Sends 2 KiB of a chunked body (over the 1 KiB limit) and then does
  /// [after]: `silent` keeps the connection open and says nothing more,
  /// `drop` destroys it 5 ms later, `eof` ends its side midway through the
  /// body. What it read back, once the server closed or 2 s passed.
  Future<String> send(String after) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    final read = BytesBuilder();
    final closed = Completer<void>();
    socket.listen(
      read.add,
      onError: (Object _) => closed.isCompleted ? null : closed.complete(),
      onDone: () => closed.isCompleted ? null : closed.complete(),
    );
    socket.add(
      latin1.encode(
        'POST /bytes HTTP/1.1\r\n'
        'Host: localhost\r\n'
        'Transfer-Encoding: chunked\r\n'
        'Content-Type: application/octet-stream\r\n\r\n'
        '400\r\n${'a' * 1024}\r\n'
        '400\r\n${'b' * 1024}\r\n',
      ),
    );
    await socket.flush();
    switch (after) {
      case 'drop':
        await Future<void>.delayed(const Duration(milliseconds: 5));
        socket.destroy();
        return '';
      case 'eof':
        await socket.close();
    }
    await closed.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    socket.destroy();
    return latin1.decode(read.takeBytes());
  }

  Future<void> expectSettled() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (engine.inFlight > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // What the release of the rest may still report comes now.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(engine.inFlight, 0, reason: 'not in flight');
    final errors = [
      for (final record in logs.records)
        if (record.level.index >= LogLevel.error.index) record.message,
    ];
    expect(errors, isEmpty, reason: 'no uncaught error in the request');
  }

  test('a streamed 413 to a client that stays silent', () async {
    await serve(answer: 'stream');
    final answer = await send('silent');
    expect(answer, startsWith('HTTP/1.1 413'));
    await expectSettled();
  });

  test('a streamed 413 that fails to write, to a client that stays '
      'silent', () async {
    await serve(answer: 'failing-stream');
    await send('silent');
    await expectSettled();
  });

  test('a streamed 413 that fails to write, to a client that goes away '
      'at once', () async {
    await serve(answer: 'failing-stream');
    await send('drop');
    await expectSettled();
  });

  test('a streamed 413 to a client that ends its side midway through the '
      'body', () async {
    await serve(answer: 'stream');
    final answer = await send('eof');
    expect(answer, startsWith('HTTP/1.1 413'));
    await expectSettled();
  });

  test('two refused bodies at once, each in a request zone of its own: '
      'neither zone gets an error from its rest, both settle', () async {
    await serve(answer: 'stream');
    final answers = await Future.wait([
      send('eof'),
      send('silent'),
      send('eof'),
      send('silent'),
    ]);
    for (final answer in answers) {
      expect(answer, startsWith('HTTP/1.1 413'));
    }
    await expectSettled();
  });
}
