import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class BodyHeaders implements HttpHeaders {
  final values = <String, List<String>>{
    'host': ['localhost'],
    'content-type': ['application/x-www-form-urlencoded'],
    'content-length': ['1000'],
  };
  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];
  @override
  void forEach(void Function(String, List<String>) action) =>
      values.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class Incoming extends Stream<Uint8List> implements HttpRequest {
  final source = StreamController<Uint8List>();
  StreamSubscription<Uint8List>? reading;

  Future<void> dispose() async {
    await reading?.cancel();
    await source.close();
  }

  @override
  final headers = BodyHeaders();
  @override
  String get method => 'POST';
  @override
  Uri get uri => Uri(path: '/candidate');
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => reading = source.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('request scopes release an interrupted body read', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) => router.put('/candidate', (_) => 'put'),
        )
        .create();
    await app.boot();
    app.kernel.defaultTimeout = const Duration(milliseconds: 30);
    final incoming = Incoming();
    final request = Request.fromHttpRequest(incoming, id: 'lifecycle');
    try {
      final response = await app.handle(request);
      expect(response.status, 503);
      expect(request.hasUnreadBody, isFalse);
      expect(incoming.source.hasListener, isFalse);
      expect(incoming.source.isPaused, isFalse);
    } finally {
      await incoming.dispose();
      await app.shutdown();
    }
  });
}
