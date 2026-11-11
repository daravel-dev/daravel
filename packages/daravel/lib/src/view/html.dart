import 'dart:convert';

import '../foundation/html_escape.dart';
import '../http/request.dart';
import '../http/response.dart';

export '../foundation/html_escape.dart';

/// A typed HTML tree: text and attributes are escaped, raw markup has to be
/// asked for ([raw]), and a node returned from a handler is sent as HTML.
///
/// ```dart
/// import 'package:daravel/html.dart';
///
/// HtmlNode userCard(User user) => div(classes: 'card', [
///   h2([user.name]),                       // escaped
///   p(classes: 'muted', [user.email]),
///   if (user.isAdmin) span(classes: 'badge', ['Admin']),
/// ]);
///
/// router.get('/users/{id}', (request) async =>
///     document(title: 'Profile', [userCard(await find(request))]));
/// ```
///
/// Children are a list of nodes, strings (escaped text), numbers, `null`
/// (skipped) and nested lists.
abstract base class HtmlNode implements Responsable {
  /// Nodes are immutable.
  const HtmlNode();

  /// Writes the node's HTML to [out].
  void writeTo(StringSink out);

  /// The node's HTML.
  String render() {
    final out = StringBuffer();
    writeTo(out);
    return out.toString();
  }

  @override
  Response toResponse(Request request) => Response.html(render());

  @override
  String toString() => render();
}

/// Text, escaped (Blade's `{{ $value }}`).
final class TextNode extends HtmlNode {
  /// Text, escaped when written.
  const TextNode(this.text);

  /// The text.
  final String text;

  @override
  void writeTo(StringSink out) => out.write(escapeHtml(text));
}

/// Markup written as is (Blade's `{!! $value !!}`): only for trusted HTML.
final class RawHtml extends HtmlNode {
  /// HTML written as given; never pass it user input.
  const RawHtml(this.html);

  /// The HTML.
  final String html;

  @override
  void writeTo(StringSink out) => out.write(html);
}

/// The content of a `<script>` or `<style>` element. HTML entities mean
/// nothing there, so it is not escaped; instead every `</script` is
/// written `<\/script` (`</style` as `<\/style`), and in a script every `<!--` is
/// written `<\!--`, so the content cannot end the element early or switch
/// the parser into a state where it misses the end tag. Inside a JavaScript
/// string or a CSS string both spellings mean the same characters.
final class RawTextNode extends HtmlNode {
  /// [text] as the content of a [tag] (`script` or `style`) element.
  const RawTextNode(this.text, {required this.tag});

  /// The content.
  final String text;

  /// The element the content is written into.
  final String tag;

  @override
  void writeTo(StringSink out) => out.write(guardRawText(text, tag: tag));

  /// [text] made safe to write inside a [tag] element (see [RawTextNode]).
  static String guardRawText(String text, {required String tag}) {
    var safe = text.replaceAllMapped(
      RegExp('</($tag)', caseSensitive: false),
      (m) => '<\\/${m[1]}',
    );
    if (tag.toLowerCase() == 'script') {
      safe = safe.replaceAll('<!--', '<\\!--');
    }
    return safe;
  }
}

/// Several nodes without a wrapping element.
final class Fragment extends HtmlNode {
  /// Several nodes without a wrapping element.
  Fragment(List<Object?> children) : children = _nodes(children);

  /// The nodes.
  final List<HtmlNode> children;

  @override
  void writeTo(StringSink out) {
    for (final child in children) {
      child.writeTo(out);
    }
  }
}

/// An element with attributes and children.
final class Element extends HtmlNode {
  /// An element.
  Element(
    this.tag, {
    List<Object?> children = const [],
    Map<String, Object?> attributes = const {},
    String? id,
    String? classes,
  }) : children = _nodes(children),
       attributes = {'id': ?id, 'class': ?classes, ...attributes};

  /// The tag name.
  final String tag;

  /// The child nodes.
  final List<HtmlNode> children;

  /// `true` writes the bare attribute (`disabled`); `false`/`null` omit it.
  final Map<String, Object?> attributes;

  /// The elements without a closing tag.
  static const Set<String> voidTags = {
    'area',
    'base',
    'br',
    'col',
    'embed',
    'hr',
    'img',
    'input',
    'link',
    'meta',
    'source',
    'track',
    'wbr',
  };

  @override
  void writeTo(StringSink out) {
    out.write('<$tag');
    writeAttributes(out, attributes);
    out.write('>');
    if (voidTags.contains(tag)) {
      return;
    }
    for (final child in children) {
      child.writeTo(out);
    }
    out.write('</$tag>');
  }

  /// Writes [attributes] as ` key="value"`: `true` as the bare key,
  /// `false` and `null` not at all, values escaped.
  static void writeAttributes(StringSink out, Map<String, Object?> attributes) {
    for (final MapEntry(:key, :value) in attributes.entries) {
      switch (value) {
        case null || false:
          break;
        case true:
          out.write(' $key');
        default:
          out.write(' $key="${escapeHtml('$value')}"');
      }
    }
  }
}

/// A whole page: `<!doctype html>`, `<head>` with [title], charset and
/// viewport, and [body].
final class HtmlDocument extends HtmlNode {
  /// A whole page.
  HtmlDocument(
    List<Object?> body, {
    this.title = '',
    List<Object?> head = const [],
    this.lang = 'en',
    this.bodyAttributes = const {},
  }) : body = _nodes(body),
       head = _nodes(head);

  /// The `<title>`.
  final String title;

  /// The `lang` of `<html>`.
  final String lang;

  /// The nodes of `<head>`.
  final List<HtmlNode> head;

  /// The nodes of `<body>`.
  final List<HtmlNode> body;

  /// The attributes of `<body>` (`class`, `hx-headers`, ...).
  final Map<String, Object?> bodyAttributes;

  @override
  void writeTo(StringSink out) {
    out.write('<!doctype html>');
    Element(
      'html',
      attributes: {'lang': lang},
      children: [
        Element(
          'head',
          children: [
            meta(attributes: {'charset': 'utf-8'}),
            meta(
              name: 'viewport',
              content: 'width=device-width, initial-scale=1',
            ),
            Element('title', children: [title]),
            ...head,
          ],
        ),
        Element('body', attributes: bodyAttributes, children: body),
      ],
    ).writeTo(out);
  }
}

List<HtmlNode> _nodes(List<Object?> children) {
  final nodes = <HtmlNode>[];
  void add(Object? child) {
    switch (child) {
      case null:
        break;
      case final HtmlNode node:
        nodes.add(node);
      case final Iterable<Object?> list:
        list.forEach(add);
      default:
        nodes.add(TextNode('$child'));
    }
  }

  children.forEach(add);
  return nodes;
}

// -----------------------------------------------------------------------------
// Builders
//
// Every element helper takes `id`, `classes` and `attributes`; `attributes`
// is written last, so it can also override a helper's own attribute.
// -----------------------------------------------------------------------------

/// Escaped text.
TextNode text(Object? value) => TextNode('${value ?? ''}');

/// Trusted markup, written as is.
RawHtml raw(String html) => RawHtml(html);

/// Nodes without a wrapping element.
Fragment fragment(List<Object?> children) => Fragment(children);

/// A whole page; [bodyAttributes] go on `<body>`.
HtmlDocument document(
  List<Object?> body, {
  String title = '',
  List<Object?> head = const [],
  String lang = 'en',
  Map<String, Object?> bodyAttributes = const {},
}) => HtmlDocument(
  body,
  title: title,
  head: head,
  lang: lang,
  bodyAttributes: bodyAttributes,
);

/// Any element: `el('details', [...], attributes: {'open': true})`.
Element el(
  String tag, [
  List<Object?> children = const [],
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
]) => Element(
  tag,
  children: children,
  id: id,
  classes: classes,
  attributes: attributes,
);

Element _tag(
  String tag,
  List<Object?> children,
  String? id,
  String? classes,
  Map<String, Object?> attributes,
) => Element(
  tag,
  children: children,
  id: id,
  classes: classes,
  attributes: attributes,
);

/// A `<div>`.
Element div(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('div', children, id, classes, attributes);

/// A `<span>`.
Element span(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('span', children, id, classes, attributes);

/// A `<p>`.
Element p(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('p', children, id, classes, attributes);

/// An `<h1>`.
Element h1(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('h1', children, id, classes, attributes);

/// An `<h2>`.
Element h2(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('h2', children, id, classes, attributes);

/// An `<h3>`.
Element h3(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('h3', children, id, classes, attributes);

/// A `<section>`.
Element section(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('section', children, id, classes, attributes);

/// A `<header>`.
Element header(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('header', children, id, classes, attributes);

/// A `<footer>`.
Element footer(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('footer', children, id, classes, attributes);

/// A `<nav>`.
Element nav(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('nav', children, id, classes, attributes);

/// An `<article>`.
Element article(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('article', children, id, classes, attributes);

/// `<main>` (`main` is the Dart entry point name).
Element mainEl(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('main', children, id, classes, attributes);

/// A `<strong>`.
Element strong(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('strong', children, id, classes, attributes);

/// An `<em>`.
Element em(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('em', children, id, classes, attributes);

/// A `<code>`.
Element code(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('code', children, id, classes, attributes);

/// A `<pre>`.
Element pre(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('pre', children, id, classes, attributes);

/// A `<ul>`.
Element ul(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('ul', children, id, classes, attributes);

/// An `<ol>`.
Element ol(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('ol', children, id, classes, attributes);

/// An `<li>`.
Element li(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('li', children, id, classes, attributes);

/// A `<table>`.
Element table(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('table', children, id, classes, attributes);

/// A `<thead>`.
Element thead(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('thead', children, id, classes, attributes);

/// A `<tbody>` (an htmx row-swap target: `attributes: {'hx-target': ...}`).
Element tbody(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('tbody', children, id, classes, attributes);

/// A `<tr>`.
Element tr(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('tr', children, id, classes, attributes);

/// A `<th>`.
Element th(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('th', children, id, classes, attributes);

/// A `<td>`.
Element td(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('td', children, id, classes, attributes);

/// An `<a>` linking to the given URL.
Element a(
  List<Object?> children, {
  required String href,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('a', children, id, classes, {'href': href, ...attributes});

/// A `<button>`.
Element button(
  List<Object?> children, {
  String type = 'button',
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('button', children, id, classes, {'type': type, ...attributes});

/// A `<form>`.
Element form(
  List<Object?> children, {
  required String action,
  String method = 'POST',
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('form', children, id, classes, {
  'action': action,
  'method': method,
  ...attributes,
});

/// A `<label>`.
Element label(
  List<Object?> children, {
  String? forId,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('label', children, id, classes, {'for': forId, ...attributes});

/// A `<textarea>`.
Element textarea({
  required String name,
  String value = '',
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('textarea', [value], id, classes, {'name': name, ...attributes});

/// An `<input>`.
Element input({
  required String name,
  String type = 'text',
  Object? value,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('input', const [], id, classes, {
  'type': type,
  'name': name,
  'value': value,
  ...attributes,
});

/// An `<img>`.
Element img({
  required String src,
  required String alt,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) =>
    _tag('img', const [], id, classes, {'src': src, 'alt': alt, ...attributes});

/// A `<meta>`: `meta(name: 'description', content: '...')`, or any other
/// form through [attributes] (`{'property': 'og:title', 'content': ...}`).
Element meta({
  String? name,
  String? content,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('meta', const [], id, classes, {
  'name': name,
  'content': content,
  ...attributes,
});

/// A `<link rel=... href=...>`; [attributes] carries `integrity`,
/// `crossorigin`, `media`, `as`, `type`...
Element link({
  required String rel,
  required String href,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('link', const [], id, classes, {
  'rel': rel,
  'href': href,
  ...attributes,
});

/// A `<br>`.
Element br({
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('br', const [], id, classes, attributes);

/// An `<hr>`.
Element hr({
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('hr', const [], id, classes, attributes);

/// A `<script>`: an external one (`script(src: '/app.js', defer: true)`)
/// or an inline one (`script(content: 'start()')`), not both.
///
/// Inline [content] is written as JavaScript, not escaped, so it must be
/// trusted code; a `</script` or `<!--` in it is defused (see
/// [RawTextNode]) so it cannot close the element. To hand data to a
/// script, use [jsonScript] rather than interpolating it into [content].
/// [module] writes `type="module"`; [nonce] is the request's
/// Content-Security-Policy nonce, for a page whose `script-src` lists one.
Element script({
  String? src,
  String? content,
  bool defer = false,
  bool async = false,
  bool module = false,
  String? nonce,
  String? integrity,
  String? crossorigin,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) {
  if (src != null && content != null) {
    throw ArgumentError(
      'A <script> has either a src or inline content, not both.',
    );
  }
  return _tag(
    'script',
    [if (content != null) RawTextNode(content, tag: 'script')],
    id,
    classes,
    {
      'src': src,
      'type': module ? 'module' : null,
      'defer': defer,
      'async': async,
      'nonce': nonce,
      'integrity': integrity,
      'crossorigin': crossorigin,
      ...attributes,
    },
  );
}

/// A `<script type="application/json">` holding [data] as JSON, the safe
/// way to give a script server data: `<`, `>`, `&`, U+2028 and U+2029 are
/// written as `\u` escapes, so no value can close the element. Read it with
/// `JSON.parse(document.getElementById(id).textContent)`.
Element jsonScript(
  Object? data, {
  required String id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag(
  'script',
  [RawHtml(_scriptSafeJson(jsonEncode(data)))],
  id,
  classes,
  {'type': 'application/json', ...attributes},
);

/// An inline `<style>` with [css]; a `</style` in it is defused (see
/// [RawTextNode]). [nonce] is the request's Content-Security-Policy nonce.
Element style(
  String css, {
  String? media,
  String? nonce,
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag(
  'style',
  [RawTextNode(css, tag: 'style')],
  id,
  classes,
  {'media': media, 'nonce': nonce, ...attributes},
);

String _scriptSafeJson(String json) {
  final out = StringBuffer();
  for (var i = 0; i < json.length; i++) {
    final unit = json.codeUnitAt(i);
    switch (unit) {
      // < > & U+2028 U+2029
      case 0x3C || 0x3E || 0x26 || 0x2028 || 0x2029:
        out
          ..writeCharCode(0x5C) // backslash
          ..write('u')
          ..write(unit.toRadixString(16).padLeft(4, '0'));
      default:
        out.writeCharCode(unit);
    }
  }
  return out.toString();
}
