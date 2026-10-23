import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Who may do what with [User] records (registered in `bootstrap/app.dart`).
final class UserPolicy extends Policy<User> {
  const UserPolicy();

  @override
  Object? viewAny(Authenticatable? user) => true;

  @override
  Object? view(Authenticatable? user, User model) => true;

  /// Users may only edit their own profile.
  @override
  Object? update(Authenticatable? user, User model) =>
      user is User && user.id == model.id
      ? true
      : const AuthResponse.deny('You may only update your own profile.');

  @override
  Object? delete(Authenticatable? user, User model) => update(user, model);
}
