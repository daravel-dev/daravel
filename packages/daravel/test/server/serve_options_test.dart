import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Port and host resolution for local runs and container platforms
/// (Cloud Run, Railway, Render, Fly.io inject `PORT`).
void main() {
  ServeOptions resolve(Map<String, String> values) =>
      ServeOptions.fromEnv(Env.fromMap(values));

  test('defaults to 127.0.0.1:8000', () {
    final options = resolve(const {});
    expect(options.host, '127.0.0.1');
    expect(options.port, 8000);
  });

  test('APP_PORT and APP_HOST win', () {
    final options = resolve(const {
      'APP_PORT': '9000',
      'APP_HOST': '10.0.0.5',
      'PORT': '8080',
    });
    expect(options.port, 9000);
    expect(options.host, '10.0.0.5');
  });

  test('a platform PORT is used and binds every interface', () {
    final options = resolve(const {'PORT': '8080'});
    expect(options.port, 8080);
    expect(options.host, '0.0.0.0');
  });

  test('APP_HOST still overrides the platform default host', () {
    final options = resolve(const {'PORT': '8080', 'APP_HOST': '127.0.0.1'});
    expect(options.host, '127.0.0.1');
  });

  test('a non-numeric PORT is ignored', () {
    final options = resolve(const {'PORT': 'http'});
    expect(options.port, 8000);
    expect(options.host, '127.0.0.1');
  });
}
