import 'package:daravel/daravel.dart';

import 'grants.dart';
import 'room_service.dart';
import 'token.dart';
import 'webhook.dart';

/// The LiveKit server (`LIVEKIT_URL`, or `LIVEKIT_HOST` as older apps name
/// it) and its API key and secret (`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`
/// or `LIVEKIT_SECRET_KEY`).
final class LivekitConfig implements ConfigSection {
  const LivekitConfig({
    this.url = 'http://127.0.0.1:7880',
    this.apiKey = '',
    this.apiSecret = '',
  });

  factory LivekitConfig.fromEnv(Env env) => LivekitConfig(
    url:
        env.maybeString('LIVEKIT_URL') ??
        env.string('LIVEKIT_HOST', 'http://127.0.0.1:7880'),
    apiKey: env.string('LIVEKIT_API_KEY', ''),
    apiSecret:
        env.maybeString('LIVEKIT_API_SECRET') ??
        env.string('LIVEKIT_SECRET_KEY', ''),
  );

  final String url;
  final String apiKey;
  final String apiSecret;

  /// Warns when the key and the secret are missing (LiveKit is not in use
  /// yet); fails the boot when the key is set but the secret is not, since
  /// an empty secret would sign tokens LiveKit refuses and verify webhooks
  /// anyone could forge.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final livekit = config.section<LivekitConfig>();
    return [
      if (livekit.apiKey.isNotEmpty && livekit.apiSecret.isEmpty)
        const ConfigIssue(
          ConfigIssueLevel.error,
          'LiveKit: LIVEKIT_API_KEY is set but LIVEKIT_API_SECRET is empty; '
          'tokens and webhooks need both.',
        )
      else if (livekit.apiKey.isEmpty || livekit.apiSecret.isEmpty)
        const ConfigIssue(
          ConfigIssueLevel.warning,
          'LiveKit: set LIVEKIT_API_KEY and LIVEKIT_API_SECRET before issuing '
          'tokens or calling the room service.',
        ),
    ];
  }

  @override
  String get key => 'livekit';

  @override
  Map<String, Object?> toMap() => {
    'url': url,
    'api_key': apiKey,
    'api_secret': apiSecret.isEmpty ? '' : '********',
  };
}

/// `withLivekit()` on the application builder.
extension LivekitApplicationBuilder on ApplicationBuilder {
  /// Adds LiveKit: [LivekitConfig] from `.env`, the [Livekit] facade and a
  /// [RoomServiceClient] through the application's HTTP client.
  ApplicationBuilder withLivekit() =>
      withConfig<LivekitConfig>(LivekitConfig.fromEnv)
          .withConfigCheck(LivekitConfig.check)
          .withBindings(
            (container) => container.singleton<RoomServiceClient>((c) {
              final config = c
                  .make<ConfigRepository>()
                  .section<LivekitConfig>();
              return RoomServiceClient(
                config.url,
                apiKey: config.apiKey,
                apiSecret: config.apiSecret,
                http: c.make<HttpClientFactory>(),
              );
            }),
          );
}

/// LiveKit from anywhere in a request, job or command.
abstract final class Livekit {
  static LivekitConfig get config =>
      Container.current.make<ConfigRepository>().section<LivekitConfig>();

  /// The room service.
  static RoomServiceClient get rooms =>
      Container.current.make<RoomServiceClient>();

  /// A token signed with the configured key and secret.
  static LivekitToken token({
    String? identity,
    String? name,
    String? metadata,
    Map<String, String>? attributes,
    Duration ttl = const Duration(hours: 4),
    VideoGrant? video,
  }) {
    final config = Livekit.config;
    return LivekitToken(
      apiKey: config.apiKey,
      apiSecret: config.apiSecret,
      identity: identity,
      name: name,
      metadata: metadata,
      attributes: attributes,
      ttl: ttl,
      video: video,
    );
  }

  /// The verified webhook of [request]; [LivekitWebhookException] (401)
  /// when it is not LiveKit's.
  static Future<LivekitWebhookEvent> webhook(
    Request request, {
    Duration? maxAge = const Duration(minutes: 5),
  }) {
    final config = Livekit.config;
    return LivekitWebhookReceiver(
      apiKey: config.apiKey,
      apiSecret: config.apiSecret,
      maxAge: maxAge,
    ).fromRequest(request);
  }
}
