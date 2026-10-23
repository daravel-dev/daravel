import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Users API backed by the `User` model.
final class UserController {
  /// `GET /api/users` — paginated list.
  Future<Object?> index(Request request) async => User.query()
      .orderByDesc('id')
      .paginate(
        page: int.tryParse(request.query['page'] ?? '') ?? 1,
        perPage: 15,
        path: '/api/users',
      );

  /// `GET /api/users/{id}`
  Future<Object?> show(Request request) async {
    final user = await User.find(request.param<int>('id'));
    if (user == null) {
      abort(404, 'User [${request.param<int>('id')}] not found.');
    }
    return <String, Object?>{'data': user};
  }

  /// `POST /api/users`
  Future<Object?> store(Request request) async {
    final data = await FormRequest.run(const StoreUserRequest(), request);
    final user = await DB.transaction(
      () async => User.create({
        'name': data.string('name'),
        'email': data.string('email'),
        'password': await Hash.make(data.string('password')),
      }),
    );
    return Response.created(<String, Object?>{'data': user});
  }

  /// `PATCH /api/users/{id}` — only the owner may update (see `UserPolicy`).
  Future<Object?> update(Request request) async {
    final user = await User.findOrFail(request.param<int>('id'));
    await request.authorize('update', [user]);
    final data = await request.validate({
      'name': 'required|string|min:2|max:100',
    });
    await user.update({'name': data.string('name')});
    return <String, Object?>{'data': user};
  }
}
