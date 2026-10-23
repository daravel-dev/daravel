import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Factory for [User] (`User.factory()` style helper below).
ModelFactory<User> userFactory({Faker? faker}) => ModelFactory<User>(
  User.definition,
  (Faker f) => <String, Object?>{
    'name': f.name(),
    'email': f.email(),
    // Hashing arrives with the auth slice (S8).
    'password': 'plain:password',
  },
  states: {
    'unverified': (_) => <String, Object?>{'email_verified_at': null},
  },
  faker: faker,
);
