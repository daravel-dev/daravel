import 'package:daravel/daravel.dart';
import 'package:daravel_livekit/daravel_livekit.dart';

/// `POST /api/rooms/{room}/join` signs a join token; LiveKit's webhooks land
/// on `POST /api/livekit/webhook`.
Application createApp() =>
    Application.configure(basePath: '.')
        .withLivekit()
        .withRouting(
          api: (router) {
            router.post('/rooms/{room}/join', (request) async {
              final room = request.param<String>('room');
              final token = await Livekit.token(
                identity: request.header('x-user') ?? 'guest',
                video: VideoGrant(roomJoin: true, room: room),
              ).toJwt();
              return {'token': token, 'url': Livekit.config.url};
            });
            router.post('/livekit/webhook', (request) async {
              final event = await Livekit.webhook(request);
              Log.info('LiveKit ${event.event}', {'room': event.room?.name});
              return Response.noContent();
            });
          },
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
