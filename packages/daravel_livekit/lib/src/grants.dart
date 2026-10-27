/// What a token lets its holder do in LiveKit (the `video` claim), with
/// LiveKit's field names. A field left null is not sent, so the server's
/// default applies (`canPublish` and `canSubscribe` default to true there).
final class VideoGrant {
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

  factory VideoGrant.fromJson(Map<String, Object?> json) => VideoGrant(
    roomJoin: json['roomJoin'] as bool?,
    room: json['room'] as String?,
    roomCreate: json['roomCreate'] as bool?,
    roomList: json['roomList'] as bool?,
    roomRecord: json['roomRecord'] as bool?,
    roomAdmin: json['roomAdmin'] as bool?,
    ingressAdmin: json['ingressAdmin'] as bool?,
    canPublish: json['canPublish'] as bool?,
    canSubscribe: json['canSubscribe'] as bool?,
    canPublishData: json['canPublishData'] as bool?,
    canPublishSources: (json['canPublishSources'] as List<Object?>?)
        ?.map((s) => '$s')
        .toList(),
    canUpdateOwnMetadata: json['canUpdateOwnMetadata'] as bool?,
    hidden: json['hidden'] as bool?,
    recorder: json['recorder'] as bool?,
    canSubscribeMetrics: json['canSubscribeMetrics'] as bool?,
    destinationRoom: json['destinationRoom'] as String?,
  );

  /// Join [room].
  final bool? roomJoin;

  /// The room the grant is for (`roomJoin`, `roomAdmin`).
  final String? room;
  final bool? roomCreate;
  final bool? roomList;
  final bool? roomRecord;

  /// Moderate [room]: mute, remove and update participants.
  final bool? roomAdmin;
  final bool? ingressAdmin;
  final bool? canPublish;
  final bool? canSubscribe;
  final bool? canPublishData;

  /// What may be published (`camera`, `microphone`, `screen_share`,
  /// `screen_share_audio`); all when null.
  final List<String>? canPublishSources;
  final bool? canUpdateOwnMetadata;

  /// Not shown to other participants.
  final bool? hidden;
  final bool? recorder;
  final bool? canSubscribeMetrics;
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
