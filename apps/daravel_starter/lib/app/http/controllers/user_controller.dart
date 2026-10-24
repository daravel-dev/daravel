import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';
import 'package:daravel_starter/app/http/resources/user_resource.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Users API backed by the `User` model and [UserResource].
final class UserController {
  /// `GET /api/users` — paginated `{data, links, meta}`.
  Future<Object?> index(Request request) async => JsonResource.collection(
    await User.query().orderByDesc('id').paginate(perPage: 15),
    UserResource.new,
  );

  /// `GET /api/users/{id}`
  Future<Object?> show(Request request) async {
    final user = await User.find(request.param<int>('id'));
    if (user == null) {
      abort(404, 'User [${request.param<int>('id')}] not found.');
    }
    return UserResource(user);
  }

  /// `POST /api/users` — 201 because the model was just created.
  Future<Object?> store(Request request) async {
    final data = await FormRequest.run(const StoreUserRequest(), request);
    final user = await DB.transaction(
      () async => User.create({
        'name': data.string('name'),
        'email': data.string('email'),
        'password': await Hash.make(data.string('password')),
      }),
    );
    return UserResource(user);
  }

  /// `PATCH /api/users/{id}` — only the owner may update (see `UserPolicy`).
  Future<Object?> update(Request request) async {
    final user = await User.findOrFail(request.param<int>('id'));
    await request.authorize('update', [user]);
    final data = await request.validate({
      'name': 'required|string|min:2|max:100',
    });
    await user.update({'name': data.string('name')});
    return UserResource(user);
  }
}
