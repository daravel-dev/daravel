import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('static beats param beats wildcard', () {
    final tree = RadixTree<String>()
      ..insert('/users/new', 'static')
      ..insert('/users/{id}', 'param')
      ..insert('/users/{path*}', 'wild');

    expect(tree.lookup('/users/new')!.value, 'static');

    final param = tree.lookup('/users/42')!;
    expect(param.value, 'param');
    expect(param.params, <String, String>{'id': '42'});

    final wild = tree.lookup('/users/42/posts/7')!;
    expect(wild.value, 'wild');
    expect(wild.params, <String, String>{'path': '42/posts/7'});
  });

  test('backtracks from a static dead end to a parameter branch', () {
    final tree = RadixTree<String>()
      ..insert('/users/new/edit', 'static')
      ..insert('/users/{id}/posts', 'param');

    final match = tree.lookup('/users/new/posts')!;
    expect(match.value, 'param');
    expect(match.params['id'], 'new');
    expect(tree.lookup('/users/new'), isNull);
  });

  test('supports colon syntax and normalizes slashes', () {
    final tree = RadixTree<String>()..insert('posts/:slug/', 'post');
    expect(tree.lookup('/posts/hello-world/')!.params['slug'], 'hello-world');
    expect(tree.lookup('//posts//hello')!.params['slug'], 'hello');
    expect(tree.lookup('/posts'), isNull);
    expect(tree.lookup('/posts/a/b'), isNull);
  });

  test('matches the root path', () {
    final tree = RadixTree<String>()..insert('/', 'root');
    expect(tree.lookup('/')!.value, 'root');
    expect(tree.lookup('')!.value, 'root');
    expect(tree.lookup('/x'), isNull);
  });

  test('decodes percent-encoded parameters', () {
    final tree = RadixTree<String>()..insert('/files/{name}', 'file');
    expect(tree.lookup('/files/a%20b')!.params['name'], 'a b');
  });

  test('wildcard needs at least one segment and takes the rest', () {
    final tree = RadixTree<String>()..insert('/assets/*path', 'assets');
    expect(tree.lookup('/assets'), isNull);
    expect(tree.lookup('/assets/css/app.css')!.params['path'], 'css/app.css');
  });

  test('rejects conflicting parameter names and misplaced wildcards', () {
    final tree = RadixTree<int>()..insert('/a/{x}', 1);
    expect(() => tree.insert('/a/{y}', 2), throwsArgumentError);
    expect(() => tree.insert('/a/{rest*}/b', 3), throwsArgumentError);
  });

  test('last registration wins for the same path', () {
    final tree = RadixTree<int>()
      ..insert('/a', 1)
      ..insert('/a', 2);
    expect(tree.lookup('/a')!.value, 2);
  });
}
