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
      final int n => n,
      // A number past what an int holds (1e400 decodes as infinity) reads
      // as 0, like a missing one, rather than throwing.
      final double n when n.isFinite && n.abs() < 9.2e18 => n.toInt(),
      final String s => int.tryParse(s) ?? 0,
      _ => 0,
    };

/// The string [name] of [json], or empty.
String stringField(Map<String, Object?> json, String name) =>
    switch (field(json, name)) {
      null => '',
      final Object value => '$value',
    };

/// The boolean [name] of [json], or false.
bool boolField(Map<String, Object?> json, String name) =>
    field(json, name) == true;

DateTime? _seconds(int seconds) => seconds == 0
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

/// A room on the LiveKit server.
final class LivekitRoom {
  /// A room from the API's [json].
  LivekitRoom(this.json);

  /// The message as the server sent it.
  final Map<String, Object?> json;

  /// The room's server id.
  String get sid => stringField(json, 'sid');

  /// The room's name.
  String get name => stringField(json, 'name');

  /// Closed this long after the last participant left.
  Duration get emptyTimeout =>
      Duration(seconds: intField(json, 'empty_timeout'));

  /// How long the room stays after the last participant leaves.
  Duration get departureTimeout =>
      Duration(seconds: intField(json, 'departure_timeout'));

  /// The most participants allowed; 0 for no limit.
  int get maxParticipants => intField(json, 'max_participants');

  /// When the room was created.
  DateTime? get createdAt => _seconds(intField(json, 'creation_time'));

  /// The room's metadata.
  String get metadata => stringField(json, 'metadata');

  /// The participants in the room.
  int get numParticipants => intField(json, 'num_participants');

  /// The participants publishing.
  int get numPublishers => intField(json, 'num_publishers');

  /// Whether a recording is running.
  bool get activeRecording => boolField(json, 'active_recording');

  @override
  String toString() => 'LivekitRoom($name, $numParticipants participants)';
}

/// A participant of a room.
final class LivekitParticipant {
  /// A participant from the API's [json].
  LivekitParticipant(this.json);

  /// The raw JSON.
  final Map<String, Object?> json;

  /// The participant's server id.
  String get sid => stringField(json, 'sid');

  /// The identity given in the token.
  String get identity => stringField(json, 'identity');

  /// The display name.
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

  /// The participant's metadata.
  String get metadata => stringField(json, 'metadata');

  /// When the participant joined.
  DateTime? get joinedAt => _seconds(intField(json, 'joined_at'));

  /// Whether the participant publishes.
  bool get isPublisher => boolField(json, 'is_publisher');

  /// The participant's attributes.
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
  /// What a participant may do.
  const ParticipantPermission({
    this.canSubscribe,
    this.canPublish,
    this.canPublishData,
    this.canPublishSources,
    this.hidden,
    this.canUpdateMetadata,
  });

  /// May subscribe to tracks.
  final bool? canSubscribe;

  /// May publish tracks.
  final bool? canPublish;

  /// May send data messages.
  final bool? canPublishData;

  /// The track sources it may publish.
  final List<String>? canPublishSources;

  /// Hidden from other participants.
  final bool? hidden;

  /// May change its metadata.
  final bool? canUpdateMetadata;

  /// The permission as JSON.
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
