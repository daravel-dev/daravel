import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class FakeUser implements Authenticatable {
  const FakeUser(this.id, {this.admin = false});

  final int id;
  final bool admin;

  @override
  Object get authIdentifier => id;
  @override
  String get authIdentifierName => 'id';
  @override
  String? get authPassword => null;
  @override
  String get authPasswordName => 'password';
  @override
  String? get rememberToken => null;
}

final class Post {
  const Post(this.ownerId, {this.published = false});
  final int ownerId;
  final bool published;
}

final class Draft extends Post {
  const Draft(super.ownerId);
}

final class PostPolicy extends Policy<Post> {
  const PostPolicy();

  @override
  Object? viewAny(Authenticatable? user) => true;

  @override
  Object? view(Authenticatable? user, Post model) =>
      model.published || (user is FakeUser && user.id == model.ownerId);

  @override
  Object? create(Authenticatable? user) => user != null;

  @override
  Object? update(Authenticatable? user, Post model) =>
      user is FakeUser && user.id == model.ownerId
      ? true
      : const AuthResponse.deny('You do not own this post.', 'not-owner');

  @override
  Map<String, GateCallback> get extra => {
    'publish': (user, args) => user is FakeUser && user.admin,
  };
}

void main() {
  const owner = FakeUser(1);
  const stranger = FakeUser(2);
  const admin = FakeUser(3, admin: true);
  const post = Post(1);

  AuthorizationGate gateFor(Authenticatable? user) =>
      AuthorizationGate(userResolver: () async => user)
        ..policy<Post>(const PostPolicy())
        ..define('edit-settings', (user, _) => user is FakeUser && user.admin);

  test('policies dispatch standard abilities by model type', () async {
    final gate = gateFor(owner);
    expect(await gate.allows('viewAny', [Post]), isTrue);
    expect(await gate.allows('view', [post]), isTrue);
    expect(await gate.allows('update', [post]), isTrue);
    expect(await gate.allows('delete', [post]), isFalse); // default deny
    expect(await gate.allows('create', [Post]), isTrue);
    expect(await gateFor(null).allows('create', [Post]), isFalse);
    expect(await gateFor(stranger).allows('view', [post]), isFalse);
    expect(
      await gateFor(stranger).allows('view', [const Post(1, published: true)]),
      isTrue,
    );
    // Subclasses match through the `is` check.
    expect(await gate.allows('update', [const Draft(1)]), isTrue);
  });

  test('inspect carries message and code; authorize throws 403', () async {
    final gate = gateFor(stranger);
    final response = await gate.inspect('update', [post]);
    expect(response.denied, isTrue);
    expect(response.message, 'You do not own this post.');
    expect(response.code, 'not-owner');
    expect(
      () => gate.authorize('update', [post]),
      throwsA(
        isA<AuthorizationException>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.message, 'message', 'You do not own this post.')
            .having((e) => e.code, 'code', 'not-owner'),
      ),
    );
    expect((await gateFor(owner).authorize('update', [post])).allowed, isTrue);
  });

  test('abilities, extra policy abilities, undefined → deny', () async {
    expect(await gateFor(admin).allows('edit-settings'), isTrue);
    expect(await gateFor(owner).denies('edit-settings'), isTrue);
    expect(await gateFor(admin).allows('publish', [post]), isTrue);
    expect(await gateFor(owner).allows('publish', [post]), isFalse);
    expect(await gateFor(admin).allows('does-not-exist'), isFalse);
    expect(gateFor(admin).has('edit-settings'), isTrue);
    expect(
      await gateFor(admin).check(['edit-settings', 'publish'], [post]),
      isTrue,
    );
    expect(
      await gateFor(owner).any(['edit-settings', 'update'], [post]),
      isTrue,
    );
    expect(
      await gateFor(owner).none(['edit-settings', 'publish'], [post]),
      isTrue,
    );
  });

  test('before hooks short-circuit, after hooks may override', () async {
    final gate = gateFor(stranger)
      ..before(
        (user, ability, _) => user is FakeUser && user.admin ? true : null,
      );
    expect(await gate.allows('update', [post]), isFalse);
    expect(await gate.forUser(admin).allows('update', [post]), isTrue);
    expect(await gate.forUser(admin).allows('delete', [post]), isTrue);

    final audited = <String>[];
    gate.after((user, ability, result, _) {
      audited.add('$ability:${result.allowed}');
      return ability == 'delete' ? true : null;
    });
    expect(await gate.allows('delete', [post]), isTrue);
    expect(await gate.allows('update', [post]), isFalse);
    expect(audited, ['delete:false', 'update:false']);
  });

  test(
    'forUser evaluates for another user without touching the resolver',
    () async {
      var resolved = 0;
      final gate = AuthorizationGate(
        userResolver: () async {
          resolved++;
          return owner;
        },
      )..policy<Post>(const PostPolicy());
      expect(await gate.forUser(stranger).allows('update', [post]), isFalse);
      expect(await gate.forUser(null).allows('create', [Post]), isFalse);
      expect(resolved, 0);
      expect(await gate.allows('update', [post]), isTrue);
      expect(resolved, 1);
    },
  );
}
