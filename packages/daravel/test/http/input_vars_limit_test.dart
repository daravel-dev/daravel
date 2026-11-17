import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Directory, Platform, Socket;
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/http/multipart.dart'
    show MultipartBody, parseMultipart;
import 'package:test/test.dart';

void main() {
  test('generated inputs within the limit match the original parser', () {
    for (var seed = 0; seed < 500; seed++) {
      final random = Random(seed);
      final keys = [
        'a',
        'a[]',
        'a[b]',
        'a[0][]',
        'b[1]',
        'x%5B%5D',
        '%zz',
        '',
        'plain',
      ];
      final values = ['1', '', 'a+b', '%2B', '%zz', 'x%3Dy'];
      final query = List.generate(
        1 + random.nextInt(60),
        (_) =>
            '${keys[random.nextInt(keys.length)]}=${values[random.nextInt(values.length)]}',
      ).join('&');
      expect(
        parseQueryString(query),
        legacyParseQueryString(query),
        reason: 'seed $seed',
      );
    }
  });
  test(
    'rejects the 1001st query pair, including duplicates and malformed pairs',
    () {
      expect(parseQueryString(List.filled(1000, 'x=1').join('&&'))['x'], '1');
      expect(
        () => parseQueryString(List.filled(1001, 'x=1').join('&')),
        throwsA(isA<BadRequestHttpException>()),
      );
      expect(
        () => parseQueryString(List.filled(1001, '%zz=1').join('&')),
        throwsA(isA<BadRequestHttpException>()),
      );
      expect(
        () => parseQueryString('x=1', maxInputVars: 0),
        throwsArgumentError,
      );
    },
  );

  test('over-limit form fails again on a second read', () async {
    final request = Request.fake(
      method: 'POST',
      body: List.filled(1001, 'x=1').join('&'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
    );
    await expectLater(request.body(), throwsA(isA<BadRequestHttpException>()));
    await expectLater(request.body(), throwsA(isA<BadRequestHttpException>()));
  });

  test('query getters and configurable limit reject the same excess', () {
    final request = Request.fake(path: '/?x=1&x=2&x=3')..maxInputVars = 2;
    expect(() => request.query, throwsA(isA<BadRequestHttpException>()));
    expect(() => request.queryMulti, throwsA(isA<BadRequestHttpException>()));
    expect(() => request.queryInput, throwsA(isA<BadRequestHttpException>()));
    expect(() => request.queryInput, throwsA(isA<BadRequestHttpException>()));
    request.maxInputVars = 3;
    expect(request.queryInput['x'], '3');
  });

  test('reviewer form and query shapes are rejected', () async {
    final nested = StringBuffer();
    var i = 0;
    while (nested.length < 980 * 1024) {
      if (nested.isNotEmpty) nested.write('&');
      nested.write('a[k${i++}]${'[0]' * 30}=1');
    }
    final array = List.filled(174763, 'x[]=1').join('&');
    final query = List.filled(74898, 'x[]=1').join('&');
    expect(query.length, 449387);
    final dir = Directory.systemTemp.createTempSync('input-vars-cases-');
    final app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'HTTP_MAX_FORM_BODY': '2097152',
        })
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get('/read', (request) => request.queryInput);
            router.post('/read', (request) async => await request.body());
          },
        )
        .create();
    try {
      await app.boot();
      for (final body in [nested.toString(), array]) {
        final request = Request.fake(
          method: 'POST',
          path: '/read',
          body: body,
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        );
        expect((await app.handle(request)).status, 400);
      }
      expect(
        (await app.handle(Request.fake(path: '/read?$query'))).status,
        400,
      );
      final engine = ServerEngine(
        app,
        const ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          maxHeaderBytes: 1 << 20,
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
      try {
        final socket = await Socket.connect('127.0.0.1', engine.port!);
        socket.write(
          'GET /read?$query HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
        );
        await socket.flush();
        final response = await utf8.decoder
            .bind(socket)
            .join()
            .timeout(const Duration(seconds: 10));
        expect(response, startsWith('HTTP/1.1 400'));
        socket.destroy();
      } finally {
        await engine.stop();
      }
    } finally {
      await app.shutdown();
      dir.deleteSync(recursive: true);
    }
  });

  test('multipart counts fields and files together before nesting', () async {
    const body =
        '--b\r\nContent-Disposition: form-data; name="a"\r\n\r\n1\r\n'
        '--b\r\nContent-Disposition: form-data; name="f"; filename="a.txt"\r\n\r\nx\r\n--b--\r\n';
    Future<MultipartBody> parse(int maxParts) => parseMultipart(
      Stream.value(utf8.encode(body)),
      'b',
      limits: MultipartLimits(maxParts: maxParts),
    );
    await expectLater(parse(1), throwsA(isA<BadRequestHttpException>()));
    final accepted = await parse(2);
    expect(accepted.fields, containsPair('a', '1'));
    expect(accepted.files, hasLength(1));
    for (final file in accepted.files) {
      await file.delete();
    }
  });

  test(
    'environment limit reaches request handling and rejects invalid values',
    () async {
      final dir = Directory.systemTemp.createTempSync('input-vars-');
      Application make(String limit) =>
          Application.configure(basePath: dir.path)
              .withEnv({
                'APP_ENV': 'testing',
                'DB_DATABASE': ':memory:',
                'HTTP_MAX_INPUT_VARS': limit,
              })
              .withRouting(
                apiPrefix: '',
                api: (router) {
                  router.get('/read', (request) => request.queryInput);
                  router.post('/read', (request) async => await request.body());
                },
              )
              .create();
      final app = make('2');
      try {
        await app.boot();
        expect(
          (await app.handle(Request.fake(path: '/read?a=1&b=2'))).status,
          200,
        );
        expect(
          (await app.handle(Request.fake(path: '/read?a=1&b=2&c=3'))).status,
          400,
        );
        expect(
          (await app.handle(
            Request.fake(
              method: 'POST',
              path: '/read',
              body: 'a=1&b=2&c=3',
              headers: {'content-type': 'application/x-www-form-urlencoded'},
            ),
          )).status,
          400,
        );
      } finally {
        await app.shutdown();
      }
      final invalid = make('0');
      await expectLater(invalid.boot(), throwsArgumentError);
      dir.deleteSync(recursive: true);
    },
  );

  test('CI reports input parser costs for long and numerous values', () {
    final prefix = List.filled(1001, 'x=1').join('&');
    final cases = <String, String>{
      'over-limit-short': prefix,
      'over-limit-long-tail': '$prefix${'z' * (1024 * 1024)}',
      'long-value': 'x=${'a' * (1024 * 1024)}',
      'distinct-values': List.generate(1000, (i) => 'k$i=$i').join('&'),
      'many-items': List.filled(1000, 'x[]=1').join('&'),
    };
    for (final entry in cases.entries) {
      void parse() {
        try {
          parseQueryString(entry.value);
        } on BadRequestHttpException {
          // The over-limit cases are expected to be refused.
        }
      }

      parse();
      final timer = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        parse();
      }
      timer.stop();
      // CI logs retain the input size and total elapsed time for review.
      print(
        'input-vars ${entry.key}: ${entry.value.length} bytes, 20 runs, ${timer.elapsedMicroseconds} us',
      );
    }
  }, skip: Platform.environment['CI'] != 'true' ? 'CI timing only' : false);
}

Map<String, Object?> legacyParseQueryString(String query, {int maxDepth = 32}) {
  final pairs = <(String, Object)>[];
  for (final pair in query.split('&')) {
    if (pair.isEmpty) {
      continue;
    }
    final equals = pair.indexOf('=');
    final String key;
    final String value;
    try {
      key = Uri.decodeQueryComponent(
        equals == -1 ? pair : pair.substring(0, equals),
      );
      value = equals == -1
          ? ''
          : Uri.decodeQueryComponent(pair.substring(equals + 1));
    } on ArgumentError {
      continue; // Malformed percent-encoding: PHP drops it too.
    }
    pairs.add((key, value));
  }
  return buildInput(pairs, maxDepth: maxDepth);
}

/// Nests `name[key][]`-style [pairs] into maps and lists, as PHP fills
/// `$_GET`, `$_POST` and `$_FILES` (used for query strings, form bodies and
/// multipart fields and files).
Map<String, Object?> buildInput(
  Iterable<(String, Object)> pairs, {
  int maxDepth = 32,
}) {
  final result = <String, Object?>{};
  // The next `[]` index of every map built here (PHP's nNextFreeElement):
  // finding it by scanning the map's keys made `a[]=` pairs quadratic.
  final nextIndex = HashMap<Map<String, Object?>, int>.identity();
  for (final (key, value) in pairs) {
    final open = key.indexOf('[');
    final segments = <String>[];
    if (open > 0) {
      var cursor = open;
      while (cursor < key.length && key[cursor] == '[') {
        final close = key.indexOf(']', cursor);
        if (close == -1) {
          break;
        }
        segments.add(key.substring(cursor + 1, close));
        cursor = close + 1;
      }
    }
    if (segments.length > maxDepth) {
      continue;
    }
    _putQueryValue(
      result,
      segments.isEmpty ? key : key.substring(0, open),
      segments,
      value,
      nextIndex,
    );
  }
  // The top level stays a map even for keys like `0`, `1`.
  return <String, Object?>{
    for (final entry in result.entries) entry.key: _listify(entry.value),
  };
}

void _putQueryValue(
  Map<String, Object?> map,
  String key,
  List<String> segments,
  Object value,
  Map<Map<String, Object?>, int> nextIndex,
) {
  if (segments.isEmpty) {
    _noteKey(map, key, nextIndex);
    map[key] = value;
    return;
  }
  var child = map[key];
  if (child is! Map<String, Object?>) {
    child = <String, Object?>{};
    _noteKey(map, key, nextIndex);
    map[key] = child;
  }
  var next = segments.first;
  if (next.isEmpty) {
    // `[]` appends at the next integer index, as in PHP: one past the
    // highest integer key so far.
    next = '${nextIndex[child] ?? 0}';
  }
  _putQueryValue(child, next, segments.sublist(1), value, nextIndex);
}

/// Keeps the next `[]` index of [map] one past its highest integer key.
void _noteKey(
  Map<String, Object?> map,
  String key,
  Map<Map<String, Object?>, int> nextIndex,
) {
  final number = int.tryParse(key);
  if (number != null && number >= (nextIndex[map] ?? 0)) {
    nextIndex[map] = number + 1;
  }
}

Object? _listify(Object? value) {
  if (value is! Map<String, Object?>) {
    return value;
  }
  final converted = <String, Object?>{
    for (final entry in value.entries) entry.key: _listify(entry.value),
  };
  var index = 0;
  final sequential = converted.keys.every((key) => key == '${index++}');
  if (sequential && converted.isNotEmpty) {
    return converted.values.toList();
  }
  return converted;
}
