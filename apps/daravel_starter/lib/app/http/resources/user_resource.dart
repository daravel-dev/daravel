import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/models/user.dart';

/// API representation of [User] (Laravel `UserResource`).
final class UserResource extends JsonResource<User> {
  UserResource(super.resource);

  /// JSON Schema of [toArray], for `.returns(...)` (OpenAPI, generated clients).
  static const Map<String, Object?> schema = {
    'type': 'object',
    'required': ['id', 'name', 'email', 'email_verified'],
    'properties': {
      'id': {'type': 'integer'},
      'name': {'type': 'string'},
      'email': {'type': 'string', 'format': 'email'},
      'email_verified': {'type': 'boolean'},
      'created_at': {
        'type': ['string', 'null'],
        'format': 'date-time',
      },
    },
  };

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'name': resource.name,
    'email': resource.email,
    'email_verified': resource.emailVerifiedAt != null,
    'created_at': resource.createdAt,
  };
}
