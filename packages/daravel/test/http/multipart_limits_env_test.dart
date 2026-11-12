import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `HTTP_MULTIPART_*` set the limits a multipart body is read with
/// ([MultipartLimits.fromEnv]); the kernel gives them to every request, so
/// a request from the test client is read as a served one is.
void main() {
  group('MultipartLimits.fromEnv', () {
    test('unset: the defaults', () {
      final limits = MultipartLimits.fromEnv(Env.fromMap(const {}));
      const defaults = MultipartLimits();
      expect(limits.maxParts, defaults.maxParts);
      expect(limits.maxFiles, defaults.maxFiles);
      expect(limits.maxFieldBytes, defaults.maxFieldBytes);
      expect(limits.maxPartHeaderBytes, defaults.maxPartHeaderBytes);
      expect(limits.maxPartHeaders, defaults.maxPartHeaders);
      expect(limits.anyUnlimited, isFalse);
    });

    test('values, 0 for no limit, a negative value refused', () {
      final limits = MultipartLimits.fromEnv(
        Env.fromMap(const {
          'HTTP_MULTIPART_MAX_PARTS': '50',
          'HTTP_MULTIPART_MAX_FILES': '0',
          'HTTP_MULTIPART_MAX_FIELD_BYTES': '2048',
          'HTTP_MULTIPART_MAX_PART_HEADER_BYTES': '4096',
          'HTTP_MULTIPART_MAX_PART_HEADERS': '10',
        }),
      );
      expect(limits.maxParts, 50);
      expect(limits.maxFiles, MultipartLimits.unlimited);
      expect(limits.maxFieldBytes, 2048);
      expect(limits.maxPartHeaderBytes, 4096);
      expect(limits.maxPartHeaders, 10);
      expect(limits.anyUnlimited, isTrue);
      expect(
        () => MultipartLimits.fromEnv(
          Env.fromMap(const {'HTTP_MULTIPART_MAX_PARTS': '-1'}),
        ),
        throwsArgumentError,
      );
    });
  });

  group('through the kernel', () {
    late Application app;
    late Directory base;

    Future<Application> boot(Map<String, String> env) async {
      base = Directory.systemTemp.createTempSync('daravel_mp_env');
      final built = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
          .withRouting(
            api: (r) {
              r.post(
                '/form',
                (req) async => {'fields': (await req.all()).length},
              );
            },
          )
          .create();
      await built.boot();
      return built;
    }

    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    // Two fields and a file: three parts.
    Request threeParts() => Request.fake(
      method: 'POST',
      path: '/api/form',
      form: const {'a': '1', 'b': '2'},
      files: {'f': UploadedFile.fake.create('x.txt', kilobytes: 1)},
    );

    test('HTTP_MULTIPART_MAX_PARTS=2 refuses three parts with 400', () async {
      app = await boot(const {'HTTP_MULTIPART_MAX_PARTS': '2'});
      final response = await app.handle(threeParts());
      expect(response.status, 400);
      expect(await response.bodyText(), contains('Too many form fields.'));
    });

    test('HTTP_MULTIPART_MAX_PARTS=3 takes them', () async {
      app = await boot(const {'HTTP_MULTIPART_MAX_PARTS': '3'});
      final response = await app.handle(threeParts());
      expect(response.status, 200);
    });
  });
}
