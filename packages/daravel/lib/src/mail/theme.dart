import 'package:markdown/markdown.dart' as md;

import 'mailable.dart' show escapeHtml;

/// The look of markdown mail and notification mail: Laravel 12's default
/// mail theme (`resources/views/vendor/mail/html/themes/default.css`), with
/// its styles inlined into every element, as Laravel does before sending,
/// since many mail clients ignore `<style>`.
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withMailTheme(
///       (theme) => theme.copyWith(primary: '#4f46e5', logoUrl: 'https://…'),
///     )
/// ```
final class MailTheme {
  const MailTheme({
    required this.appName,
    this.appUrl = 'http://localhost',
    this.logoUrl,
    this.primary = '#18181b',
    this.success = '#16a34a',
    this.error = '#dc2626',
    this.text = '#52525b',
    this.heading = '#18181b',
    this.background = '#fafafa',
    this.surface = '#ffffff',
    this.border = '#e4e4e7',
    this.muted = '#a1a1aa',
    this.footer,
  });

  /// Shown in the header and the footer (`APP_NAME`).
  final String appName;

  /// The header links here (`APP_URL`).
  final String appUrl;

  /// An image in the header instead of [appName].
  final String? logoUrl;

  /// Button colors by level, as `<x-mail::button :color>`.
  final String primary;
  final String success;
  final String error;

  final String text;
  final String heading;

  /// Around the message, and the panel background.
  final String background;

  /// The message itself.
  final String surface;
  final String border;

  /// The footer.
  final String muted;

  /// Footer markdown; `© <year> <app>. All rights reserved.` by default.
  final String? footer;

  MailTheme copyWith({
    String? appName,
    String? appUrl,
    String? logoUrl,
    String? primary,
    String? success,
    String? error,
    String? text,
    String? heading,
    String? background,
    String? surface,
    String? border,
    String? muted,
    String? footer,
  }) => MailTheme(
    appName: appName ?? this.appName,
    appUrl: appUrl ?? this.appUrl,
    logoUrl: logoUrl ?? this.logoUrl,
    primary: primary ?? this.primary,
    success: success ?? this.success,
    error: error ?? this.error,
    text: text ?? this.text,
    heading: heading ?? this.heading,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    border: border ?? this.border,
    muted: muted ?? this.muted,
    footer: footer ?? this.footer,
  );

  static const String _font =
      "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, "
      "Arial, sans-serif, 'Apple Color Emoji', 'Segoe UI Emoji', "
      "'Segoe UI Symbol'";

  /// A button (Laravel's `<x-mail::button>`), to put in markdown:
  /// `color` is `primary`, `success` or `error`.
  String button(String label, String url, {String color = 'primary'}) {
    final background = switch (color) {
      'success' || 'green' => success,
      'error' || 'red' => error,
      _ => primary,
    };
    return '<table class="action" align="center" width="100%" cellpadding="0" '
        'cellspacing="0" role="presentation" style="box-sizing: border-box; '
        'font-family: $_font; margin: 30px auto; padding: 0; '
        'text-align: center; width: 100%;"><tr><td align="center">'
        '<table border="0" cellpadding="0" cellspacing="0" role="presentation">'
        '<tr><td><a href="${escapeHtml(url)}" class="button button-$color" '
        'target="_blank" rel="noopener" style="box-sizing: border-box; '
        'font-family: $_font; border-radius: 4px; color: #fff; '
        'display: inline-block; overflow: hidden; text-decoration: none; '
        'background-color: $background; border-bottom: 8px solid $background; '
        'border-left: 18px solid $background; '
        'border-right: 18px solid $background; '
        'border-top: 8px solid $background;">${escapeHtml(label)}</a>'
        '</td></tr></table></td></tr></table>';
  }

  /// A highlighted block (Laravel's `<x-mail::panel>`) of [markdown].
  String panel(String markdown) =>
      '<table class="panel" width="100%" cellpadding="0" cellspacing="0" '
      'role="presentation" style="box-sizing: border-box; font-family: $_font; '
      'border-left: $primary solid 4px; margin: 21px 0;"><tr>'
      '<td class="panel-content" style="box-sizing: border-box; '
      'font-family: $_font; background-color: $background; color: $text; '
      'padding: 16px;">${render(markdown)}</td></tr></table>';

  /// [markdown] as HTML with the theme's inline styles. Laravel's mail
  /// components work as they are written in Blade (see [mailButton] and
  /// [mailPanel]):
  ///
  /// ```markdown
  /// <x-mail::button url="https://example.com/orders/7" color="success">
  /// Track your order
  /// </x-mail::button>
  ///
  /// <x-mail::panel>
  /// Your code is **4821**.
  /// </x-mail::panel>
  /// ```
  String render(String markdown) {
    final withComponents = markdown
        .replaceAllMapped(_buttonTag, (m) {
          final attributes = _attributes(m[1]!);
          return '\n\n${button(_unescape(m[2]!.trim()), attributes['url'] ?? '#', color: attributes['color'] ?? 'primary')}\n\n';
        })
        .replaceAllMapped(_panelTag, (m) => '\n\n${panel(m[1]!.trim())}\n\n');
    return _inline(
      md.markdownToHtml(
        withComponents,
        extensionSet: md.ExtensionSet.gitHubWeb,
      ),
    );
  }

  static final RegExp _buttonTag = RegExp(
    r'<x-mail::button\b([^>]*)>(.*?)</x-mail::button>',
    dotAll: true,
  );
  static final RegExp _panelTag = RegExp(
    r'<x-mail::panel>(.*?)</x-mail::panel>',
    dotAll: true,
  );

  static Map<String, String> _attributes(String source) => {
    for (final m in RegExp(r'([\w-]+)="([^"]*)"').allMatches(source))
      m[1]!: _unescape(m[2]!),
  };

  /// A whole message: header, [body] (HTML from [render]), an optional
  /// [subcopy] (markdown) and the footer, as Laravel's `mail::message`.
  String layout(String body, {String? subcopy}) {
    final year = DateTime.now().year;
    final header = logoUrl == null
        ? escapeHtml(appName)
        : '<img src="${escapeHtml(logoUrl!)}" alt="${escapeHtml(appName)}" '
              'style="height: 75px; margin-top: 15px; margin-bottom: 10px; '
              'max-height: 75px; width: 75px;">';
    final footerHtml =
        render(footer ?? '© $year ${escapeHtml(appName)}. All rights reserved.')
            .replaceAllMapped(
              RegExp('<p style="[^"]*">'),
              (_) =>
                  '<p style="box-sizing: border-box; font-family: $_font; '
                  'line-height: 1.5em; margin-top: 0; color: $muted; '
                  'font-size: 12px; text-align: center;">',
            )
            .replaceAllMapped(
              RegExp('<a ([^>]*?)style="[^"]*">'),
              (m) =>
                  '<a ${m[1]}style="color: $muted; '
                  'text-decoration: underline;">',
            );
    final subcopyHtml = subcopy == null
        ? ''
        : '<table class="subcopy" width="100%" cellpadding="0" cellspacing="0" '
              'role="presentation" style="border-top: 1px solid $border; '
              'margin-top: 25px; padding-top: 25px;"><tr><td>'
              '${render(subcopy).replaceAll('font-size: 16px;', 'font-size: 14px;')}'
              '</td></tr></table>';
    return '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" '
        '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">\n'
        '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
        '<title>${escapeHtml(appName)}</title>'
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
        '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">'
        '<meta name="color-scheme" content="light">'
        '<meta name="supported-color-schemes" content="light">'
        '<style>@media only screen and (max-width: 600px) {.inner-body, .footer '
        '{width: 100% !important;}} @media only screen and (max-width: 500px) '
        '{.button {width: 100% !important;}}</style></head>'
        '<body style="box-sizing: border-box; font-family: $_font; '
        '-webkit-text-size-adjust: none; background-color: $surface; '
        'color: $text; height: 100%; line-height: 1.4; margin: 0; padding: 0; '
        'width: 100% !important;">'
        '<table class="wrapper" width="100%" cellpadding="0" cellspacing="0" '
        'role="presentation" style="background-color: $background; margin: 0; '
        'padding: 0; width: 100%;"><tr><td align="center">'
        '<table class="content" width="100%" cellpadding="0" cellspacing="0" '
        'role="presentation" style="margin: 0; padding: 0; width: 100%;">'
        '<tr><td class="header" style="padding: 25px 0; text-align: center;">'
        '<a href="${escapeHtml(appUrl)}" style="display: inline-block; '
        'color: $heading; font-size: 19px; font-weight: bold; '
        'text-decoration: none;">$header</a></td></tr>'
        '<tr><td class="body" width="100%" cellpadding="0" cellspacing="0" '
        'style="background-color: $background; border-bottom: 1px solid '
        '$background; border-top: 1px solid $background; margin: 0; '
        'padding: 0; width: 100%; border: hidden !important;">'
        '<table class="inner-body" align="center" width="570" cellpadding="0" '
        'cellspacing="0" role="presentation" style="background-color: $surface; '
        'border-color: $border; border-radius: 4px; border-width: 1px; '
        'box-shadow: 0 1px 3px 0 rgba(0, 0, 0, 0.1), 0 1px 2px -1px '
        'rgba(0, 0, 0, 0.1); margin: 0 auto; padding: 0; width: 570px;">'
        '<tr><td class="content-cell" style="max-width: 100vw; padding: 32px;">'
        '$body$subcopyHtml</td></tr></table></td></tr>'
        '<tr><td><table class="footer" align="center" width="570" '
        'cellpadding="0" cellspacing="0" role="presentation" '
        'style="margin: 0 auto; padding: 0; text-align: center; width: 570px;">'
        '<tr><td class="content-cell" align="center" style="max-width: 100vw; '
        'padding: 32px;">$footerHtml</td></tr></table></td></tr>'
        '</table></td></tr></table></body></html>';
  }

  /// Inline styles for the elements markdown produces (Laravel inlines
  /// its CSS with CssToInlineStyles). Elements that already have a style,
  /// such as a [button], keep theirs.
  String _inline(String html) {
    final styles = <String, String>{
      'p':
          'font-size: 16px; line-height: 1.5em; margin-top: 0; '
          'text-align: left; color: $text;',
      'h1':
          'color: $heading; font-size: 18px; font-weight: bold; '
          'margin-top: 0; text-align: left;',
      'h2':
          'color: $heading; font-size: 16px; font-weight: bold; '
          'margin-top: 0; text-align: left;',
      'h3':
          'color: $heading; font-size: 14px; font-weight: bold; '
          'margin-top: 0; text-align: left;',
      'a': 'color: $heading; word-break: break-all;',
      'ul': 'line-height: 1.4; text-align: left; color: $text;',
      'ol': 'line-height: 1.4; text-align: left; color: $text;',
      'blockquote': 'line-height: 1.4; text-align: left; color: $text;',
      'img': 'max-width: 100%; border: none;',
      'th': 'border-bottom: 1px solid $border; margin: 0; padding-bottom: 8px;',
      'td':
          'color: $text; font-size: 15px; line-height: 18px; margin: 0; '
          'padding: 10px 0;',
      'table': 'margin: 30px auto; width: 100%;',
    };
    return html.replaceAllMapped(
      RegExp(r'<(p|h1|h2|h3|a|ul|ol|blockquote|img|th|td|table)\b([^>]*)>'),
      (m) {
        final attributes = m[2]!;
        if (attributes.contains('style=')) {
          return m[0]!;
        }
        final style =
            'box-sizing: border-box; font-family: $_font; '
            '${styles[m[1]]!}';
        return '<${m[1]}$attributes style="$style">';
      },
    );
  }
}

/// Laravel's `<x-mail::button>`, with [label] and [url] escaped, for
/// markdown mail: `color` is `primary`, `success` or `error`.
String mailButton(String label, String url, {String color = 'primary'}) =>
    '<x-mail::button url="${escapeHtml(url)}" color="${escapeHtml(color)}">'
    '${escapeHtml(label)}</x-mail::button>';

/// Laravel's `<x-mail::panel>` around [markdown].
String mailPanel(String markdown) =>
    '<x-mail::panel>\n$markdown\n</x-mail::panel>';

/// A plain-text version of themed markdown: links and buttons as
/// `text: url`, tags removed.
String markdownToText(String markdown) {
  final text = markdown
      .replaceAllMapped(
        RegExp(
          r'<x-mail::button\b[^>]*url="([^"]*)"[^>]*>(.*?)</x-mail::button>',
          dotAll: true,
        ),
        (m) => '${m[2]!.trim()}: ${m[1]}',
      )
      .replaceAllMapped(
        RegExp(r'<a [^>]*href="([^"]*)"[^>]*>(.*?)</a>', dotAll: true),
        (m) => '${m[2]}: ${m[1]}',
      )
      .replaceAll(RegExp(r'<br\s*/?>\n?'), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAllMapped(
        RegExp(r'\[([^\]]*)\]\(([^)]*)\)'),
        (m) => '${m[1]}: ${m[2]}',
      )
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  // Last: escaped text such as `&lt;it&gt;` must not look like a tag above.
  return _unescape(text);
}

String _unescape(String text) => text
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
