import 'dart:convert';
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

  test('escapeHtml is one declaration exported by both libraries', () {
    // This file imports package:daravel/daravel.dart and
    // package:daravel/html.dart unprefixed: an ambiguous import would not
    // compile.
    expect(
      escapeHtml('<a href="x">\'&\'</a>'),
      '&lt;a href=&quot;x&quot;&gt;&#039;&amp;&#039;&lt;/a&gt;',
    );
    expect(escapeHtml('plain'), 'plain');
  });

  test('every element helper takes id, classes and attributes', () {
    final helpers =
        <String, Element Function(String?, String?, Map<String, Object?>)>{
          'div': (i, c, at) => div(const [], id: i, classes: c, attributes: at),
          'span': (i, c, at) =>
              span(const [], id: i, classes: c, attributes: at),
          'p': (i, c, at) => p(const [], id: i, classes: c, attributes: at),
          'h1': (i, c, at) => h1(const [], id: i, classes: c, attributes: at),
          'h2': (i, c, at) => h2(const [], id: i, classes: c, attributes: at),
          'h3': (i, c, at) => h3(const [], id: i, classes: c, attributes: at),
          'section': (i, c, at) =>
              section(const [], id: i, classes: c, attributes: at),
          'header': (i, c, at) =>
              header(const [], id: i, classes: c, attributes: at),
          'footer': (i, c, at) =>
              footer(const [], id: i, classes: c, attributes: at),
          'nav': (i, c, at) => nav(const [], id: i, classes: c, attributes: at),
          'article': (i, c, at) =>
              article(const [], id: i, classes: c, attributes: at),
          'main': (i, c, at) =>
              mainEl(const [], id: i, classes: c, attributes: at),
          'strong': (i, c, at) =>
              strong(const [], id: i, classes: c, attributes: at),
          'em': (i, c, at) => em(const [], id: i, classes: c, attributes: at),
          'code': (i, c, at) =>
              code(const [], id: i, classes: c, attributes: at),
          'pre': (i, c, at) => pre(const [], id: i, classes: c, attributes: at),
          'ul': (i, c, at) => ul(const [], id: i, classes: c, attributes: at),
          'ol': (i, c, at) => ol(const [], id: i, classes: c, attributes: at),
          'li': (i, c, at) => li(const [], id: i, classes: c, attributes: at),
          'table': (i, c, at) =>
              table(const [], id: i, classes: c, attributes: at),
          'thead': (i, c, at) =>
              thead(const [], id: i, classes: c, attributes: at),
          'tbody': (i, c, at) =>
              tbody(const [], id: i, classes: c, attributes: at),
          'tr': (i, c, at) => tr(const [], id: i, classes: c, attributes: at),
          'th': (i, c, at) => th(const [], id: i, classes: c, attributes: at),
          'td': (i, c, at) => td(const [], id: i, classes: c, attributes: at),
          'a': (i, c, at) =>
              a(const [], href: '/', id: i, classes: c, attributes: at),
          'button': (i, c, at) =>
              button(const [], id: i, classes: c, attributes: at),
          'form': (i, c, at) =>
              form(const [], action: '/', id: i, classes: c, attributes: at),
          'label': (i, c, at) =>
              label(const [], id: i, classes: c, attributes: at),
          'textarea': (i, c, at) =>
              textarea(name: 'n', id: i, classes: c, attributes: at),
          'input': (i, c, at) =>
              input(name: 'n', id: i, classes: c, attributes: at),
          'img': (i, c, at) =>
              img(src: '/x.png', alt: '', id: i, classes: c, attributes: at),
          'meta': (i, c, at) => meta(id: i, classes: c, attributes: at),
          'link': (i, c, at) =>
              link(rel: 'icon', href: '/i', id: i, classes: c, attributes: at),
          'br': (i, c, at) => br(id: i, classes: c, attributes: at),
          'hr': (i, c, at) => hr(id: i, classes: c, attributes: at),
          'script': (i, c, at) =>
              script(src: '/a.js', id: i, classes: c, attributes: at),
          'style': (i, c, at) => style('', id: i, classes: c, attributes: at),
        };
    for (final MapEntry(key: tag, value: build) in helpers.entries) {
      final html = build('x', 'y', const {'hx-swap': 'outerHTML'}).render();
      expect(html, startsWith('<$tag id="x" class="y"'), reason: tag);
      expect(html, contains(' hx-swap="outerHTML"'), reason: tag);
    }
  });

  test('link, meta, tbody, hr and td take the attributes they lacked', () {
    expect(
      link(
        rel: 'stylesheet',
        href: '/app.css',
        attributes: {'integrity': 'sha384-abc', 'crossorigin': 'anonymous'},
      ).render(),
      '<link rel="stylesheet" href="/app.css" integrity="sha384-abc" '
      'crossorigin="anonymous">',
    );
    expect(
      meta(name: 'description', content: 'A "quiz"').render(),
      '<meta name="description" content="A &quot;quiz&quot;">',
    );
    expect(
      meta(attributes: {'charset': 'utf-8'}).render(),
      '<meta charset="utf-8">',
    );
    expect(
      tbody(
        id: 'rows',
        attributes: {'hx-target': 'closest tr'},
        [
          tr([
            td(id: 'total', [3]),
          ]),
        ],
      ).render(),
      '<tbody id="rows" hx-target="closest tr"><tr><td id="total">3</td>'
      '</tr></tbody>',
    );
    expect(hr(classes: 'divider').render(), '<hr class="divider">');
    expect(br().render(), '<br>');
  });

  test('script: external, module, inline and defused end tags', () {
    expect(
      script(src: '/app.js', defer: true, nonce: 'abc').render(),
      '<script src="/app.js" defer nonce="abc"></script>',
    );
    expect(
      script(src: '/m.js', module: true, async: true).render(),
      '<script src="/m.js" type="module" async></script>',
    );
    expect(
      script(content: 'if (a < b && c) { go("x"); }').render(),
      '<script>if (a < b && c) { go("x"); }</script>',
    );
    // A string that would end the element or open a comment is defused.
    expect(
      script(content: 'log("</SCRIPT><b>x</b>"); var c = "<!--";').render(),
      r'<script>log("<\/SCRIPT><b>x</b>"); var c = "<\!--";</script>',
    );
    expect(() => script(src: '/a.js', content: 'x()'), throwsArgumentError);
  });

  test('jsonScript and style cannot be closed by their content', () {
    final html = jsonScript({
      'name': '</script><script>alert(1)</script>',
      'amp': 'a & b',
    }, id: 'data').render();
    expect(html, startsWith('<script id="data" type="application/json">{'));
    expect(html.indexOf('</script>'), html.length - '</script>'.length);
    expect(html, isNot(contains('&')));
    // The payload still decodes to the original values.
    final json = html.substring(
      html.indexOf('>') + 1,
      html.length - '</script>'.length,
    );
    expect(jsonDecode(json), {
      'name': '</script><script>alert(1)</script>',
      'amp': 'a & b',
    });

    expect(
      style('p::after { content: "</style>"; }', media: 'print').render(),
      r'<style media="print">p::after { content: "<\/style>"; }</style>',
    );
  });

  test('document takes body attributes (hx-headers on <body>)', () {
    final page = document(
      bodyAttributes: {
        'hx-headers': jsonEncode({'X-CSRF-TOKEN': 'abc'}),
      },
      ['hi'],
    ).render();
    expect(
      page,
      contains(
        '<body hx-headers="{&quot;X-CSRF-TOKEN&quot;:&quot;abc&quot;}">',
      ),
    );
  });

  test('htmx: request headers and HX-Redirect instead of 302', () {
    final htmx = Request.fake(
      path: '/save',
      method: 'POST',
      headers: {'HX-Request': 'true', 'HX-Target': 'row-1', 'HX-Trigger': 'b'},
    );
    final plain = Request.fake(path: '/save', method: 'POST');
    expect(htmx.isHtmx, isTrue);
    expect(htmx.isHtmxBoosted, isFalse);
    expect(htmx.htmxTarget, 'row-1');
    expect(htmx.htmxTrigger, 'b');
    expect(plain.isHtmx, isFalse);

    final viaHtmx = htmxRedirect(htmx, '/exams');
    expect(viaHtmx.status, 200);
    expect(viaHtmx.headers['hx-redirect'], '/exams');
    expect(viaHtmx.headers['location'], isNull);

    final viaBrowser = htmxRedirect(plain, '/exams', status: 303);
    expect(viaBrowser.status, 303);
    expect(viaBrowser.headers['location'], '/exams');
  });
}
