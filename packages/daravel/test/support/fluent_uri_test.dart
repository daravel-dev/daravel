import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Illuminate\Support\Uri`, compared with its behaviour in 13.x.
void main() {
  const url = 'https://ana:pw@example.com:8080/a/b?x=1&y=2#top';

  test('reads the parts', () {
    final uri = DaravelUri.of(url);
    expect(uri.scheme, 'https');
    expect(uri.host, 'example.com');
    expect(uri.port, 8080);
    expect(uri.user, 'ana');
    expect(uri.path, 'a/b');
    expect(uri.pathSegments, ['a', 'b']);
    expect(uri.fragment, 'top');
    expect(uri.query, {'x': '1', 'y': '2'});
  });

  test('the root path is a slash, with no segments', () {
    final uri = DaravelUri.of('https://example.com');
    expect(uri.path, '/');
    expect(uri.pathSegments, isEmpty);
  });

  test('values are immutable: each change is a new one', () {
    final uri = DaravelUri.of(url);
    uri.withHost('other.test');
    expect(uri.host, 'example.com');
  });

  test('with the parts', () {
    final uri = DaravelUri.of('http://example.com/a')
        .withScheme('https')
        .withHost('other.test')
        .withPort(444)
        .withPath('b/c')
        .withFragment('end');
    expect('$uri', 'https://other.test:444/b/c#end');
    expect('${uri.withoutFragment().withPort(null)}', 'https://other.test/b/c');
  });

  group('query', () {
    test('withQuery merges', () {
      expect(
        '${DaravelUri.of('http://e.test/?a=1').withQuery({'b': 2})}',
        'http://e.test/?a=1&b=2',
      );
      expect(
        '${DaravelUri.of('http://e.test/?a=1').withQuery({'a': 2})}',
        'http://e.test/?a=2',
      );
    });

    test('merge off replaces', () {
      final uri = DaravelUri.of('http://e.test/?a=1');
      expect('${uri.withQuery({'b': 2}, merge: false)}', 'http://e.test/?b=2');
      expect('${uri.replaceQuery({'c': 3})}', 'http://e.test/?c=3');
    });

    test('withQueryIfMissing keeps what is there', () {
      final uri = DaravelUri.of('http://e.test/?a=1')
          .withQueryIfMissing({'a': 9, 'b': 2});
      expect(uri.query, {'a': '1', 'b': '2'});
    });

    test('withoutQuery', () {
      final uri = DaravelUri.of('http://e.test/?a=1&b=2&c=3');
      expect('${uri.withoutQuery('a')}', 'http://e.test/?b=2&c=3');
      expect('${uri.withoutQuery(['a', 'b'])}', 'http://e.test/?c=3');
      expect('${uri.withoutQuery(['a', 'b', 'c'])}', 'http://e.test/');
    });

    test('pushOntoQuery onto a list, a value and nothing', () {
      final list = DaravelUri.of('http://e.test/?t[]=a');
      expect(list.pushOntoQuery('t', 'b').query['t'], ['a', 'b']);
      expect(list.pushOntoQuery('t', 'a').query['t'], ['a'], reason: 'unique');
      final value = DaravelUri.of('http://e.test/?t=a');
      expect(value.pushOntoQuery('t', 'b').query['t'], ['a', 'b']);
      final none = DaravelUri.of('http://e.test/');
      expect(none.pushOntoQuery('t', ['a', 'b']).query['t'], ['a', 'b']);
    });

    test('nested values use brackets, escaped like http_build_query', () {
      final uri = DaravelUri.of('http://e.test/').withQuery({
        'f': {'a': 1},
        'l': ['x', 'y z'],
      });
      expect('$uri', 'http://e.test/?f%5Ba%5D=1&l%5B0%5D=x&l%5B1%5D=y%20z');
    });

    test('decode shows the brackets again', () {
      final uri = DaravelUri.of('http://e.test/').withQuery({
        'l': ['y z'],
      });
      expect(uri.decode(), 'http://e.test/?l[0]=y z');
    });
  });

  test('isEmpty', () {
    expect(DaravelUri.of('').isEmpty, isTrue);
    expect(DaravelUri.of('/a').isEmpty, isFalse);
  });

  test('redirect', () {
    final response = DaravelUri.of('/next').redirect();
    expect(response.status, 302);
    expect(response.headers.first('location'), '/next');
  });
}
