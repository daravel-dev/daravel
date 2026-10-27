import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';

/// Serves an application with Redis or Valkey (`REDIS_HOST` and, for
/// example, `CACHE_STORE=redis` and `QUEUE_CONNECTION=redis` in `.env`).
Application createApp() =>
    Application.configure(basePath: '.')
        .withRedis()
        .withRouting(
          api: (router) => router.get('/visits', (_) async {
            final visits = await Redis.command(['INCR', 'visits']);
            return {'visits': visits};
          }),
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
