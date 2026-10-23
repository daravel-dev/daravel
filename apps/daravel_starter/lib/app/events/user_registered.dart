/// Dispatched after a user registers through the API.
final class UserRegistered {
  const UserRegistered(this.userId, this.email);

  final Object userId;
  final String email;
}
