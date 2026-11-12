import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The parameter forms a route path can hold, and which of them a URL can
/// leave out: what `dartisan names:sync` makes required or optional in
/// `Routes.*`.
void main() {
  late Router router;

  setUp(() {
    router = Router()
      ..get('/posts/{post}', (_) => null).name('posts.show')
      ..get('/users/:id', (_) => null).name('users.show')
      ..get('/blog/{post:slug}', (_) => null).name('blog.show')
      ..get('/pages/{slug?}', (_) => null).name('pages.show')
      ..get('/files/{path*}', (_) => null).name('files.show')
      ..get('/assets/*path', (_) => null).name('assets.show');
    router.compile(MiddlewareRegistry());
  });

  test('{post}, :id and {post:slug} are one segment, named without the '
      'column', () {
    expect(router.lookup('GET', '/posts/7')!.params, {'post': '7'});
    expect(router.lookup('GET', '/users/7')!.params, {'id': '7'});
    expect(router.lookup('GET', '/blog/hello')!.params, {'post': 'hello'});
    expect(router.url('blog.show', params: {'post': 'hello'}), '/blog/hello');
    expect(router.url('users.show', params: {'id': 7}), '/users/7');
  });

  test('{slug?} can be left out, in matching and in a URL', () {
    expect(router.lookup('GET', '/pages')!.value.routeName, 'pages.show');
    expect(router.url('pages.show'), '/pages');
    expect(router.url('pages.show', params: {'slug': 'about'}), '/pages/about');
  });

  test('a wildcard cannot be empty: no match, and a URL needs a value', () {
    for (final (prefix, name) in [
      ('/files', 'files.show'),
      ('/assets', 'assets.show'),
    ]) {
      expect(router.lookup('GET', prefix), isNull, reason: prefix);
      expect(router.lookup('GET', '$prefix/'), isNull, reason: '$prefix/');
      expect(
        () => router.url(name),
        throwsA(isA<ArgumentError>()),
        reason: name,
      );
      expect(router.lookup('GET', '$prefix/a/b')!.params, {'path': 'a/b'});
      expect(router.url(name, params: {'path': 'a/b c'}), '$prefix/a/b%20c');
    }
  });
}
