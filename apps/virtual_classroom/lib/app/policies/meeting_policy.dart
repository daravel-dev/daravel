import 'package:daravel/daravel.dart';

import '../models/classroom.dart';
import '../models/meeting.dart';
import '../models/user.dart';

/// The classroom's teacher manages its meetings; its students see and join
/// the published ones.
final class MeetingPolicy extends Policy<Meeting> {
  const MeetingPolicy();

  @override
  Future<Object?> view(Authenticatable? user, Meeting model) async {
    if (user is! User) {
      return false;
    }
    final classroom = await model.classroom();
    if (classroom.taughtBy(user)) {
      return true;
    }
    return model.isPublished && await classroom.attendedBy(user)
        ? true
        : const AuthResponse.deny('This meeting is not open to you.');
  }

  @override
  Future<Object?> update(Authenticatable? user, Meeting model) async =>
      user is User && (await model.classroom()).taughtBy(user)
      ? true
      : const AuthResponse.deny(
          'Only the teacher of this classroom may change its meetings.',
        );

  @override
  Future<Object?> delete(Authenticatable? user, Meeting model) =>
      update(user, model);

  /// Creating in [classroom]: its teacher only.
  static Future<bool> canCreateIn(User user, Classroom classroom) async =>
      classroom.taughtBy(user) && await user.isTeacher;
}
