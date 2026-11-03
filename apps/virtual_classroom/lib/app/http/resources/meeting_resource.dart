import 'package:daravel/daravel.dart';

import '../../models/meeting.dart';

/// A meeting as the API shows it. Its public `id` is the UUID; the integer
/// primary key never leaves the server, so the resource has no separate
/// `uuid` field.
final class MeetingResource extends JsonResource<Meeting> {
  MeetingResource(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.uuid,
    'classroom_id': resource.classroomId,
    'name': resource.name,
    'description': resource.description,
    'starts_at': resource.startsAt.toUtc().toIso8601String(),
    'ends_at': resource.endsAt.toUtc().toIso8601String(),
    'max_participants': resource.maxParticipants,
    'status': resource.status,
  };
}
