import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/html.dart';
import 'package:test/test.dart';

HtmlNode userCard(String name, {bool admin = false}) => div(classes: 'card', [
  h2([name]),
  if (admin) span(classes: 'badge', ['Admin']),
  null,
  [
    'plain ',
    strong(['bold']),
  ],
]);

void main() {
  test('text and attributes are escaped; raw is explicit', () {
    const attack = '<script>alert("x")</script> & \'quotes\'';
    expect(
      p([attack]).render(),
      '<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; '
      '&#039;quotes&#039;</p>',
    );
    expect(
      a(['go'], href: 'https://x.test/?a=1&b="2"').render(),
      '<a href="https://x.test/?a=1&amp;b=&quot;2&quot;">go</a>',
    );
    expect(div([raw('<b>trusted</b>')]).render(), '<div><b>trusted</b></div>');
    expect(text(null).render(), '');
  });

  test('children: strings, numbers, nulls, conditionals and lists', () {
    expect(
      userCard('Ana <3', admin: true).render(),
      '<div class="card"><h2>Ana &lt;3</h2>'
      '<span class="badge">Admin</span>plain <strong>bold</strong></div>',
    );
    expect(userCard('Bo').render(), isNot(contains('badge')));
    expect(
      ul([
        for (final n in [1, 2]) li([n]),
      ]).render(),
      '<ul><li>1</li><li>2</li></ul>',
    );
  });

  test('void elements, boolean attributes and forms', () {
    expect(br().render(), '<br>');
    expect(
      input(
        name: 'email',
        type: 'email',
        attributes: {'required': true, 'disabled': false},
      ).render(),
      '<input type="email" name="email" required>',
    );
    expect(
      form(action: '/login', [
        label(['Email'], forId: 'email'),
        input(name: 'email', id: 'email', value: 'a"b'),
        button(['Sign in'], type: 'submit'),
      ]).render(),
      '<form action="/login" method="POST"><label for="email">Email</label>'
      '<input id="email" type="text" name="email" value="a&quot;b">'
      '<button type="submit">Sign in</button></form>',
    );
    expect(
      el('details', ['more'], null, null, {'open': true}).render(),
      '<details open>more</details>',
    );
  });

  test('a document returned from a handler is an HTML response', () async {
    final base = Directory.systemTemp.createTempSync('daravel_html');
    addTearDown(() => base.deleteSync(recursive: true));
    final app = Application.configure(basePath: base.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          web: (r) => r.get(
            '/hello/{name}',
            (request) => document(title: 'Hello', [
              mainEl([
                h1(['Hello, ${request.param<String>('name')}']),
              ]),
            ]),
          ),
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final response = await app.handle(Request.fake(path: '/hello/%3Cb%3E'));
    expect(response.status, 200);
    expect(response.headers['content-type'], startsWith('text/html'));
    final body = await response.bodyText();
    expect(
      body,
      startsWith('<!doctype html><html lang="en"><head><meta charset="utf-8">'),
    );
    expect(body, contains('<title>Hello</title>'));
    expect(body, contains('<h1>Hello, &lt;b&gt;</h1>'));
  });
}
