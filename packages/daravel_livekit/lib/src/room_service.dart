import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'grants.dart';
import 'models.dart';
import 'token.dart';

/// The LiveKit server refused a call (a Twirp error): [code] is Twirp's
/// (`not_found`, `permission_denied`, `invalid_argument`, ...).
final class LivekitException extends DaravelException {
  const LivekitException(super.message, {required this.status, this.code});

  final int status;
  final String? code;
}

/// LiveKit's room service over Twirp (JSON): rooms, participants and data
/// messages, each call signed with a 10-minute admin token carrying only
/// the grant it needs, as LiveKit's server SDKs do.
///
/// Inside an application it sends through the application's HTTP client
/// (so `Http.fake()` stubs it); elsewhere through one of its own.
final class RoomServiceClient {
  RoomServiceClient(
    String url, {
    required this.apiKey,
    required this.apiSecret,
    this._http,
    this.timeout = const Duration(seconds: 10),
  }) : url = httpUrl(url);

  /// The server, as `http(s)://` (a `ws(s)://` URL is turned into one).
  final String url;
  final String apiKey;
  final String apiSecret;
  final Duration timeout;
  final HttpClientFactory? _http;
  HttpClientFactory? _own;

  static final Random _random = Random.secure();

  /// [url] with `ws` and `wss` as `http` and `https`, without a trailing
  /// slash.
  static String httpUrl(String url) {
    var result = url.trim();
    if (result.startsWith('wss://')) {
      result = 'https://${result.substring(6)}';
    } else if (result.startsWith('ws://')) {
      result = 'http://${result.substring(5)}';
    }
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  HttpClientFactory get _factory {
    if (_http case final HttpClientFactory http) {
      return http;
    }
    try {
      return Container.current.make<HttpClientFactory>();
    } on Object {
      return _own ??= HttpClientFactory();
    }
  }

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> body,
    VideoGrant grant,
  ) async {
    final token = await LivekitToken(
      apiKey: apiKey,
      apiSecret: apiSecret,
      ttl: const Duration(minutes: 10),
      video: grant,
    ).toJwt();
    final response = await _factory
        .request()
        .withToken(token)
        .acceptJson()
        .timeout(timeout)
        .post('$url/twirp/livekit.RoomService/$method', json: body);
    if (!response.successful) {
      Object? error;
      try {
        error = jsonDecode(response.body);
      } on FormatException {
        error = null;
      }
      final details = error is Map<String, Object?>
          ? error
          : const <String, Object?>{};
      throw LivekitException(
        '$method: ${details['msg'] ?? response.body}',
        status: response.status,
        code: details['code'] as String?,
      );
    }
    return response.body.trim().isEmpty ? const {} : response.jsonMap();
  }

  /// Creates [name] (or returns it when it exists).
  Future<LivekitRoom> createRoom(
    String name, {
    Duration? emptyTimeout,
    Duration? departureTimeout,
    int? maxParticipants,
    String? metadata,
    String? nodeId,
  }) async => LivekitRoom(
    await _call('CreateRoom', {
      'name': name,
      if (emptyTimeout != null) 'empty_timeout': emptyTimeout.inSeconds,
      if (departureTimeout != null)
        'departure_timeout': departureTimeout.inSeconds,
      'max_participants': ?maxParticipants,
      'metadata': ?metadata,
      'node_id': ?nodeId,
    }, const VideoGrant(roomCreate: true)),
  );

  /// The active rooms, or those among [names].
  Future<List<LivekitRoom>> listRooms([List<String> names = const []]) async {
    final reply = await _call('ListRooms', {
      if (names.isNotEmpty) 'names': names,
    }, const VideoGrant(roomList: true));
    return [
      for (final room in field(reply, 'rooms') as List<Object?>? ?? const [])
        if (room is Map<String, Object?>) LivekitRoom(room),
    ];
  }

  /// Closes [room] and disconnects its participants.
  Future<void> deleteRoom(String room) async {
    await _call('DeleteRoom', {
      'room': room,
    }, const VideoGrant(roomCreate: true));
  }

  Future<LivekitRoom> updateRoomMetadata(String room, String metadata) async =>
      LivekitRoom(
        await _call('UpdateRoomMetadata', {
          'room': room,
          'metadata': metadata,
        }, VideoGrant(room: room, roomAdmin: true)),
      );

  Future<List<LivekitParticipant>> listParticipants(String room) async {
    final reply = await _call('ListParticipants', {
      'room': room,
    }, VideoGrant(room: room, roomAdmin: true));
    return [
      for (final p
          in field(reply, 'participants') as List<Object?>? ?? const [])
        if (p is Map<String, Object?>) LivekitParticipant(p),
    ];
  }

  Future<LivekitParticipant> getParticipant(
    String room,
    String identity,
  ) async => LivekitParticipant(
    await _call('GetParticipant', {
      'room': room,
      'identity': identity,
    }, VideoGrant(room: room, roomAdmin: true)),
  );

  /// Disconnects [identity] from [room].
  Future<void> removeParticipant(String room, String identity) async {
    await _call('RemoveParticipant', {
      'room': room,
      'identity': identity,
    }, VideoGrant(room: room, roomAdmin: true));
  }

  /// Changes [identity]'s metadata, name, attributes or permission.
  Future<LivekitParticipant> updateParticipant(
    String room,
    String identity, {
    String? metadata,
    String? name,
    Map<String, String>? attributes,
    ParticipantPermission? permission,
  }) async => LivekitParticipant(
    await _call('UpdateParticipant', {
      'room': room,
      'identity': identity,
      'metadata': ?metadata,
      'name': ?name,
      'attributes': ?attributes,
      if (permission != null) 'permission': permission.toJson(),
    }, VideoGrant(room: room, roomAdmin: true)),
  );

  /// Mutes or unmutes one of [identity]'s tracks.
  Future<void> mutePublishedTrack(
    String room,
    String identity,
    String trackSid, {
    required bool muted,
  }) async {
    await _call('MutePublishedTrack', {
      'room': room,
      'identity': identity,
      'track_sid': trackSid,
      'muted': muted,
    }, VideoGrant(room: room, roomAdmin: true));
  }

  /// Sends [data] to everyone in [room], or to [destinationIdentities], on
  /// [topic] (`lk-chat` is LiveKit's chat).
  Future<void> sendData(
    String room,
    List<int> data, {
    DataPacketKind kind = DataPacketKind.reliable,
    List<String> destinationIdentities = const [],
    String? topic,
  }) async {
    await _call('SendData', {
      'room': room,
      'data': base64.encode(data),
      'kind': kind.index,
      if (destinationIdentities.isNotEmpty)
        'destination_identities': destinationIdentities,
      'topic': ?topic,
      'nonce': base64.encode([
        for (var i = 0; i < 16; i++) _random.nextInt(256),
      ]),
    }, VideoGrant(room: room, roomAdmin: true));
  }
}
