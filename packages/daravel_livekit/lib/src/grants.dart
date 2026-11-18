import 'package:daravel/daravel.dart' show JwtException;

/// What a token lets its holder do in LiveKit (the `video` claim), with
/// LiveKit's field names. A field left null is not sent, so the server's
/// default applies (`canPublish` and `canSubscribe` default to true there).
final class VideoGrant {
  /// What a token allows in LiveKit (`video` grant).
  const VideoGrant({
    this.roomJoin,
    this.room,
    this.roomCreate,
    this.roomList,
    this.roomRecord,
    this.roomAdmin,
    this.ingressAdmin,
    this.canPublish,
    this.canSubscribe,
    this.canPublishData,
    this.canPublishSources,
    this.canUpdateOwnMetadata,
    this.hidden,
    this.recorder,
    this.canSubscribeMetrics,
    this.destinationRoom,
  });

  /// A grant read from a token's claims; [JwtException] when a field holds
  /// another type than LiveKit's (a token is signed, but by whoever holds
  /// the secret).
  factory VideoGrant.fromJson(Map<String, Object?> json) {
    T? read<T>(String name) => switch (json[name]) {
      null => null,
      final T value => value,
      _ => throw JwtException('The video grant [$name] has the wrong type.'),
    };
    return VideoGrant(
      roomJoin: read<bool>('roomJoin'),
      room: read<String>('room'),
      roomCreate: read<bool>('roomCreate'),
      roomList: read<bool>('roomList'),
      roomRecord: read<bool>('roomRecord'),
      roomAdmin: read<bool>('roomAdmin'),
      ingressAdmin: read<bool>('ingressAdmin'),
      canPublish: read<bool>('canPublish'),
      canSubscribe: read<bool>('canSubscribe'),
      canPublishData: read<bool>('canPublishData'),
      canPublishSources: read<List<Object?>>('canPublishSources')
          ?.map((s) => '$s')
          .toList(),
      canUpdateOwnMetadata: read<bool>('canUpdateOwnMetadata'),
      hidden: read<bool>('hidden'),
      recorder: read<bool>('recorder'),
      canSubscribeMetrics: read<bool>('canSubscribeMetrics'),
      destinationRoom: read<String>('destinationRoom'),
    );
  }

  /// Join [room].
  final bool? roomJoin;

  /// The room the grant is for (`roomJoin`, `roomAdmin`).
  final String? room;

  /// May create rooms.
  final bool? roomCreate;

  /// May list rooms.
  final bool? roomList;

  /// May start recordings.
  final bool? roomRecord;

  /// Moderate [room]: mute, remove and update participants.
  final bool? roomAdmin;

  /// May manage ingress.
  final bool? ingressAdmin;

  /// May publish tracks.
  final bool? canPublish;

  /// May subscribe to tracks.
  final bool? canSubscribe;

  /// May send data messages.
  final bool? canPublishData;

  /// What may be published (`camera`, `microphone`, `screen_share`,
  /// `screen_share_audio`); all when null.
  final List<String>? canPublishSources;

  /// May change its own metadata.
  final bool? canUpdateOwnMetadata;

  /// Not shown to other participants.
  final bool? hidden;

  /// Is a recorder.
  final bool? recorder;

  /// May subscribe to metrics.
  final bool? canSubscribeMetrics;

  /// The room it may forward to.
  final String? destinationRoom;

  /// This grant with the fields [other] sets.
  VideoGrant merge(VideoGrant other) => VideoGrant(
    roomJoin: other.roomJoin ?? roomJoin,
    room: other.room ?? room,
    roomCreate: other.roomCreate ?? roomCreate,
    roomList: other.roomList ?? roomList,
    roomRecord: other.roomRecord ?? roomRecord,
    roomAdmin: other.roomAdmin ?? roomAdmin,
    ingressAdmin: other.ingressAdmin ?? ingressAdmin,
    canPublish: other.canPublish ?? canPublish,
    canSubscribe: other.canSubscribe ?? canSubscribe,
    canPublishData: other.canPublishData ?? canPublishData,
    canPublishSources: other.canPublishSources ?? canPublishSources,
    canUpdateOwnMetadata: other.canUpdateOwnMetadata ?? canUpdateOwnMetadata,
    hidden: other.hidden ?? hidden,
    recorder: other.recorder ?? recorder,
    canSubscribeMetrics: other.canSubscribeMetrics ?? canSubscribeMetrics,
    destinationRoom: other.destinationRoom ?? destinationRoom,
  );

  /// The grant as JSON claims.
  Map<String, Object?> toJson() => {
    'roomCreate': ?roomCreate,
    'roomJoin': ?roomJoin,
    'roomList': ?roomList,
    'roomRecord': ?roomRecord,
    'roomAdmin': ?roomAdmin,
    'room': ?room,
    'ingressAdmin': ?ingressAdmin,
    'canPublish': ?canPublish,
    'canSubscribe': ?canSubscribe,
    'canPublishData': ?canPublishData,
    'canPublishSources': ?canPublishSources,
    'canUpdateOwnMetadata': ?canUpdateOwnMetadata,
    'hidden': ?hidden,
    'recorder': ?recorder,
    'canSubscribeMetrics': ?canSubscribeMetrics,
    'destinationRoom': ?destinationRoom,
  };
}
