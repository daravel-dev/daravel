import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  group('typed input', () {
    final request = Request.fake(
      path: '/items',
      query: const {
        'page': '5',
        'ratio': '0.25',
        'remember': 'on',
        'archived': 'no',
        'name': '  Ana ',
        'bad': 'abc',
      },
    );

    test('input<T>() converts query strings to the requested type', () async {
      expect(await request.input<int>('page', 1), 5);
      expect(await request.input<double>('ratio'), 0.25);
      expect(await request.input<num>('page'), 5);
      expect(await request.input<bool>('remember'), isTrue);
      expect(await request.input<bool>('archived'), isFalse);
      expect(await request.input<String>('page'), '5');
      expect(await request.input<int>('bad', 7), 7);
      expect(await request.input<int>('missing', 3), 3);
      expect(await request.input<int?>('page'), 5);
    });

    test('integer, float, boolean and string match Laravel', () async {
      expect(await request.integer('page'), 5);
      expect(await request.integer('bad'), 0);
      expect(await request.integer('missing', 10), 10);
      expect(await request.float('ratio'), 0.25);
      expect(await request.boolean('remember'), isTrue);
      expect(await request.boolean('archived'), isFalse);
      expect(await request.boolean('bad'), isFalse);
      expect(await request.boolean('missing', true), isTrue);
      expect(await request.string('name'), '  Ana ');
      expect(await request.string('missing', 'x'), 'x');
    });

    test(
      'query accessors are synchronous and convert like the async ones',
      () async {
        expect(request.queryInt('page'), 5);
        expect(request.queryInt('page'), await request.integer('page'));
        expect(request.queryInt('bad'), 0);
        expect(request.queryInt('missing', 10), 10);
        expect(request.queryDouble('ratio'), 0.25);
        expect(request.queryBool('remember'), isTrue);
        expect(request.queryBool('archived'), isFalse);
        expect(request.queryBool('missing', true), isTrue);
        expect(request.queryString('name'), '  Ana ');
        expect(request.queryString('missing', 'x'), 'x');

        final nested = Request.fake(path: '/x?filter[page]=3&ids[]=1&ids[]=2');
        expect(nested.queryInt('filter.page'), 3);
        expect(nested.queryInt('ids.1'), 2);
      },
    );

    test('query accessors read the body never, and see input transformers', () {
      final post =
          Request.fake(
            method: 'POST',
            path: '/items?page=2&name=+Bo+',
            json: const {'page': 9},
          )..addInputTransformer(
            (key, value) => value is String ? value.trim() : value,
          );
      // The query string only (the body says 9), already trimmed as
      // TrimStrings trims the query in Laravel.
      expect(post.queryInt('page'), 2);
      expect(post.queryString('name'), 'Bo');
    });

    test('JSON values keep their types', () async {
      final json = Request.fake(
        method: 'POST',
        path: '/items',
        json: const {'count': 3, 'price': 9.5, 'active': true},
      );
      expect(await json.integer('count'), 3);
      expect(await json.integer('price'), 9);
      expect(await json.float('count'), 3.0);
      expect(await json.boolean('active'), isTrue);
      expect(await json.string('count'), '3');
    });
  });

  group('parseQueryString (PHP parse_str)', () {
    test('brackets build lists and maps; plain repeats keep the last', () {
      expect(
        parseQueryString(
          'ids[]=1&ids[]=2&tag=a&tag=b&filter[status]=open'
          '&filter[tags][]=x&m[0]=a&m[1]=b&sparse[1]=a&0=root',
        ),
        {
          'ids': ['1', '2'],
          'tag': 'b',
          'filter': {
            'status': 'open',
            'tags': ['x'],
          },
          'm': ['a', 'b'],
          'sparse': {'1': 'a'},
          '0': 'root',
        },
      );
    });

    test('decodes, tolerates junk and limits depth', () {
      expect(parseQueryString('a%5B%5D=1&b=x+y&c&&d=%ZZ'), {
        'a': ['1'],
        'b': 'x y',
        'c': '',
      });
      expect(parseQueryString('a[b=1'), {'a[b': '1'});
      expect(parseQueryString('a[x][y][z]=1', maxDepth: 2), isEmpty);
    });

    test('query and form input reach all() and validation', () async {
      final get = Request.fake(path: '/x', query: const {'ids[]': '1'});
      // Request.fake merges a map, so build the multi-value URI directly.
      final multi = Request.fake(path: '/x?ids[]=1&ids[]=2&f[s]=a');
      expect((await multi.all())['ids'], ['1', '2']);
      expect(await multi.input<String>('f.s'), 'a');
      expect((await get.all())['ids'], ['1']);

      final form = Request.fake(
        method: 'POST',
        path: '/x',
        form: const {'items[0][id]': '7', 'items[1][id]': '8'},
      );
      final data = await form.validate({
        'items': 'required|array',
        'items.*.id': 'required|integer',
      });
      expect(data.toMap()['items'], [
        {'id': '7'},
        {'id': '8'},
      ]);
    });
  });

  test('all() is computed once and returns an independent copy', () async {
    final request = Request.fake(
      method: 'POST',
      path: '/x',
      json: const {'name': ' Ana '},
    );
    final first = await request.all();
    first['name'] = 'changed';
    expect((await request.all())['name'], ' Ana ');
    request.addInputTransformer(
      (key, value) => value is String ? value.trim() : value,
    );
    expect((await request.all())['name'], 'Ana');
  });

  group('merge and replace', () {
    test('merge overwrites and adds body fields, as Laravel\'s', () async {
      final request = Request.fake(
        method: 'POST',
        query: const {'page': '2'},
        json: const {'data_enc': 'x', 'nonce': 'n', 'name': 'old'},
      );
      expect((await request.all())['name'], 'old', reason: 'cached first');
      await request.merge({'name': 'Ana', 'age': 17});
      final all = await request.all();
      expect(all, {
        'page': '2',
        'data_enc': 'x',
        'nonce': 'n',
        'name': 'Ana',
        'age': 17,
      });
      expect(await request.input<int>('age'), 17);
      final validated = await request.validate({'name': 'required|string'});
      expect(validated.string('name'), 'Ana');
    });

    test('replace keeps the query and drops the old body', () async {
      final request = Request.fake(
        method: 'POST',
        query: const {'page': '2'},
        json: const {'data_enc': 'x', 'nonce': 'n'},
      );
      request.replace({'name': 'Ana'});
      expect(await request.all(), {'page': '2', 'name': 'Ana'});
      expect(await request.body(), {'name': 'Ana'});
    });
  });
}
