import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/models/user.dart';

/// API representation of [User] (Laravel `UserResource`).
final class UserResource extends JsonResource<User> {
  UserResource(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'name': resource.name,
    'email': resource.email,
    'email_verified': resource.emailVerifiedAt != null,
    'created_at': resource.createdAt,
  };
}
