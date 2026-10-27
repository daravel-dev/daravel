/// A field of a protobuf JSON message (Twirp): by its proto name
/// (`max_participants`) or its JSON name (`maxParticipants`).
Object? field(Map<String, Object?> json, String name) {
  if (json.containsKey(name)) {
    return json[name];
  }
  final camel = name.replaceAllMapped(
    RegExp('_([a-z])'),
    (m) => m[1]!.toUpperCase(),
  );
  return json[camel];
}

/// A protobuf integer: a number, or a string for 64-bit ones.
int intField(Map<String, Object?> json, String name) =>
    switch (field(json, name)) {
      final num n => n.toInt(),
      final String s => int.tryParse(s) ?? 0,
      _ => 0,
    };

String stringField(Map<String, Object?> json, String name) =>
    switch (field(json, name)) {
      null => '',
      final Object value => '$value',
    };

bool boolField(Map<String, Object?> json, String name) =>
    field(json, name) == true;

DateTime? _seconds(int seconds) => seconds == 0
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

/// A room on the LiveKit server.
final class LivekitRoom {
  LivekitRoom(this.json);

  /// The message as the server sent it.
  final Map<String, Object?> json;

  String get sid => stringField(json, 'sid');
  String get name => stringField(json, 'name');

  /// Closed this long after the last participant left.
  Duration get emptyTimeout =>
      Duration(seconds: intField(json, 'empty_timeout'));
  Duration get departureTimeout =>
      Duration(seconds: intField(json, 'departure_timeout'));
  int get maxParticipants => intField(json, 'max_participants');
  DateTime? get createdAt => _seconds(intField(json, 'creation_time'));
  String get metadata => stringField(json, 'metadata');
  int get numParticipants => intField(json, 'num_participants');
  int get numPublishers => intField(json, 'num_publishers');
  bool get activeRecording => boolField(json, 'active_recording');

  @override
  String toString() => 'LivekitRoom($name, $numParticipants participants)';
}

/// A participant of a room.
final class LivekitParticipant {
  LivekitParticipant(this.json);

  final Map<String, Object?> json;

  String get sid => stringField(json, 'sid');
  String get identity => stringField(json, 'identity');
  String get name => stringField(json, 'name');

  /// `JOINING`, `JOINED`, `ACTIVE` or `DISCONNECTED`.
  String get state => switch (field(json, 'state')) {
    final String s => s,
    0 || null => 'JOINING',
    1 => 'JOINED',
    2 => 'ACTIVE',
    3 => 'DISCONNECTED',
    final Object other => '$other',
  };
  String get metadata => stringField(json, 'metadata');
  DateTime? get joinedAt => _seconds(intField(json, 'joined_at'));
  bool get isPublisher => boolField(json, 'is_publisher');

  Map<String, String> get attributes => switch (field(json, 'attributes')) {
    final Map<String, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) key: '$value',
    },
    _ => const {},
  };

  /// The tracks the participant publishes, as the server describes them.
  List<Map<String, Object?>> get tracks => [
    for (final track in field(json, 'tracks') as List<Object?>? ?? const [])
      if (track is Map<String, Object?>) track,
  ];

  @override
  String toString() => 'LivekitParticipant($identity, $state)';
}

/// What a participant may do, changed with
/// `RoomServiceClient.updateParticipant`.
final class ParticipantPermission {
  const ParticipantPermission({
    this.canSubscribe,
    this.canPublish,
    this.canPublishData,
    this.canPublishSources,
    this.hidden,
    this.canUpdateMetadata,
  });

  final bool? canSubscribe;
  final bool? canPublish;
  final bool? canPublishData;
  final List<String>? canPublishSources;
  final bool? hidden;
  final bool? canUpdateMetadata;

  Map<String, Object?> toJson() => {
    'can_subscribe': ?canSubscribe,
    'can_publish': ?canPublish,
    'can_publish_data': ?canPublishData,
    if (canPublishSources case final List<String> sources)
      'can_publish_sources': [for (final s in sources) s.toUpperCase()],
    'hidden': ?hidden,
    'can_update_metadata': ?canUpdateMetadata,
  };
}

/// How `sendData` delivers a packet.
enum DataPacketKind {
  /// In order, retransmitted when lost.
  reliable,

  /// As fast as possible, possibly lost.
  lossy,
}
