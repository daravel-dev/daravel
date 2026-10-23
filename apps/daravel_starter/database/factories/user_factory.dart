import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Factory for [User].
///
/// [passwordHash] is the stored hash for every generated user; seeders hash
/// once (`await Hash.make('password')`) and reuse it, since hashing is
/// deliberately slow and runs in a compute isolate.
ModelFactory<User> userFactory({required String passwordHash, Faker? faker}) =>
    ModelFactory<User>(
      User.definition,
      (Faker f) => <String, Object?>{
        'name': f.name(),
        'email': f.email(),
        'password': passwordHash,
      },
      states: {
        'unverified': (_) => <String, Object?>{'email_verified_at': null},
      },
      faker: faker,
    );
