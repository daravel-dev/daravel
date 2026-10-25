import '../http/request.dart';
import '../http/response.dart';

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
  const HtmlNode();

  void writeTo(StringSink out);

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
  const TextNode(this.text);
  final String text;

  @override
  void writeTo(StringSink out) => out.write(escapeHtml(text));
}

/// Markup written as is (Blade's `{!! $value !!}`): only for trusted HTML.
final class RawHtml extends HtmlNode {
  const RawHtml(this.html);
  final String html;

  @override
  void writeTo(StringSink out) => out.write(html);
}

/// Several nodes without a wrapping element.
final class Fragment extends HtmlNode {
  Fragment(List<Object?> children) : children = _nodes(children);
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
  Element(
    this.tag, {
    List<Object?> children = const [],
    Map<String, Object?> attributes = const {},
    String? id,
    String? classes,
  }) : children = _nodes(children),
       attributes = {'id': ?id, 'class': ?classes, ...attributes};

  final String tag;
  final List<HtmlNode> children;

  /// `true` writes the bare attribute (`disabled`); `false`/`null` omit it.
  final Map<String, Object?> attributes;

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
    out.write('>');
    if (voidTags.contains(tag)) {
      return;
    }
    for (final child in children) {
      child.writeTo(out);
    }
    out.write('</$tag>');
  }
}

/// A whole page: `<!doctype html>`, `<head>` with [title], charset and
/// viewport, and [body].
final class HtmlDocument extends HtmlNode {
  HtmlDocument(
    List<Object?> body, {
    this.title = '',
    List<Object?> head = const [],
    this.lang = 'en',
  }) : body = _nodes(body),
       head = _nodes(head);

  final String title;
  final String lang;
  final List<HtmlNode> head;
  final List<HtmlNode> body;

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
              attributes: {
                'name': 'viewport',
                'content': 'width=device-width, initial-scale=1',
              },
            ),
            Element('title', children: [title]),
            ...head,
          ],
        ),
        Element('body', children: body),
      ],
    ).writeTo(out);
  }
}

/// Escapes `& < > " '` for text and attribute values.
String escapeHtml(String value) {
  final out = StringBuffer();
  for (final unit in value.runes) {
    out.write(switch (unit) {
      0x26 => '&amp;',
      0x3C => '&lt;',
      0x3E => '&gt;',
      0x22 => '&quot;',
      0x27 => '&#039;',
      _ => String.fromCharCode(unit),
    });
  }
  return out.toString();
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
// -----------------------------------------------------------------------------

/// Escaped text.
TextNode text(Object? value) => TextNode('${value ?? ''}');

/// Trusted markup, written as is.
RawHtml raw(String html) => RawHtml(html);

Fragment fragment(List<Object?> children) => Fragment(children);

HtmlDocument document(
  List<Object?> body, {
  String title = '',
  List<Object?> head = const [],
  String lang = 'en',
}) => HtmlDocument(body, title: title, head: head, lang: lang);

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

Element div(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('div', children, id, classes, attributes);

Element span(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('span', children, id, classes, attributes);

Element p(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('p', children, id, classes, attributes);

Element h1(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('h1', children, id, classes, attributes);

Element h2(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('h2', children, id, classes, attributes);

Element h3(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('h3', children, id, classes, attributes);

Element section(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('section', children, id, classes, attributes);

Element header(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('header', children, id, classes, attributes);

Element footer(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('footer', children, id, classes, attributes);

Element nav(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('nav', children, id, classes, attributes);

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

Element strong(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('strong', children, null, classes, attributes);

Element em(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('em', children, null, classes, attributes);

Element code(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('code', children, null, classes, attributes);

Element pre(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('pre', children, null, classes, attributes);

Element ul(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('ul', children, id, classes, attributes);

Element ol(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('ol', children, id, classes, attributes);

Element li(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('li', children, null, classes, attributes);

Element table(
  List<Object?> children, {
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('table', children, id, classes, attributes);

Element thead(List<Object?> children) =>
    _tag('thead', children, null, null, const {});

Element tbody(List<Object?> children) =>
    _tag('tbody', children, null, null, const {});

Element tr(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('tr', children, null, classes, attributes);

Element th(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('th', children, null, classes, attributes);

Element td(
  List<Object?> children, {
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('td', children, null, classes, attributes);

Element a(
  List<Object?> children, {
  required String href,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('a', children, null, classes, {'href': href, ...attributes});

Element button(
  List<Object?> children, {
  String type = 'button',
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('button', children, null, classes, {'type': type, ...attributes});

Element form(
  List<Object?> children, {
  required String action,
  String method = 'POST',
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('form', children, null, classes, {
  'action': action,
  'method': method,
  ...attributes,
});

Element label(
  List<Object?> children, {
  String? forId,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('label', children, null, classes, {'for': forId, ...attributes});

Element textarea({
  required String name,
  String value = '',
  String? id,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('textarea', [value], id, classes, {'name': name, ...attributes});

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

Element img({
  required String src,
  required String alt,
  String? classes,
  Map<String, Object?> attributes = const {},
}) => _tag('img', const [], null, classes, {
  'src': src,
  'alt': alt,
  ...attributes,
});

Element meta({Map<String, Object?> attributes = const {}}) =>
    _tag('meta', const [], null, null, attributes);

Element link({required String rel, required String href}) =>
    _tag('link', const [], null, null, {'rel': rel, 'href': href});

Element br() => _tag('br', const [], null, null, const {});

Element hr() => _tag('hr', const [], null, null, const {});
