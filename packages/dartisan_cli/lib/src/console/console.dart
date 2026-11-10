import 'dart:async';
import 'dart:io';

/// The 16 ANSI colours `dartisan` uses (ADR-036: no truecolor).
enum Ansi {
  /// Errors, and the word-mark (brick red on most themes).
  red(31),

  /// Command names and success.
  green(32),

  /// Group headings and warnings.
  yellow(33),

  /// Information.
  cyan(36),

  /// Descriptions, next to [dim].
  gray(90);

  const Ansi(this.code);

  /// The SGR foreground code.
  final int code;
}

/// Terminal output shared by `dartisan` commands (Blueprint #137 §3.1):
/// colours and symbols only where the terminal takes them.
///
/// Colour is decided once ([colorFor]): `--no-color`, then `--ansi`, then
/// `NO_COLOR`, `DARTISAN_NO_COLOR=1` or `TERM=dumb`, then whether stdout is
/// a terminal that supports ANSI escapes. Symbols (`✔ ✖ ⚠ ℹ`) need UTF-8
/// output; otherwise `[ok] [x] [!] [i]`.
final class Console {
  /// A console writing to [out] and [err] (stdout and stderr by default).
  /// [color], [unicode] and [terminal] default to what stdout supports.
  Console({
    StringSink? out,
    StringSink? err,
    bool? color,
    bool? unicode,
    bool? terminal,
    int? width,
  }) : out = out ?? stdout,
       err = err ?? stderr,
       terminal = terminal ?? stdout.hasTerminal,
       color =
           color ??
           colorFor(
             environment: Platform.environment,
             hasTerminal: stdout.hasTerminal,
             supportsAnsi: stdout.supportsAnsiEscapes,
           ),
       unicode = unicode ?? stdout.encoding.name == 'utf-8',
       width = width ?? _terminalWidth();

  /// The console for a run with the global `--no-color` and `--ansi` flags.
  factory Console.forFlags({required bool noColor, required bool ansi}) =>
      Console(
        color: colorFor(
          noColorFlag: noColor,
          ansiFlag: ansi,
          environment: Platform.environment,
          hasTerminal: stdout.hasTerminal,
          supportsAnsi: stdout.supportsAnsiEscapes,
        ),
      );

  /// Whether to colour, in ADR-036's order: [noColorFlag] (`--no-color`),
  /// [ansiFlag] (`--ansi`, for a pager such as `less -R`), `NO_COLOR`
  /// (non-empty, https://no-color.org), `DARTISAN_NO_COLOR=1` or
  /// `TERM=dumb`, then a terminal that supports ANSI escapes.
  static bool colorFor({
    bool noColorFlag = false,
    bool ansiFlag = false,
    required Map<String, String> environment,
    required bool hasTerminal,
    required bool supportsAnsi,
  }) {
    if (noColorFlag) {
      return false;
    }
    if (ansiFlag) {
      return true;
    }
    if ((environment['NO_COLOR'] ?? '').isNotEmpty ||
        environment['DARTISAN_NO_COLOR'] == '1' ||
        environment['TERM'] == 'dumb') {
      return false;
    }
    return hasTerminal && supportsAnsi;
  }

  static int _terminalWidth() {
    try {
      return stdout.hasTerminal ? stdout.terminalColumns : 80;
    } on StdoutException {
      return 80;
    }
  }

  /// Where output goes.
  final StringSink out;

  /// Where errors go.
  final StringSink err;

  /// Whether text is coloured.
  final bool color;

  /// Whether symbols and box lines may be UTF-8.
  final bool unicode;

  /// Whether stdout is a terminal (the banner and spinners need one).
  final bool terminal;

  /// The terminal's columns (80 when unknown).
  final int width;

  /// [text] in [fg], bold or dim when colouring, else as it is.
  String style(String text, {Ansi? fg, bool bold = false, bool dim = false}) {
    if (!color || text.isEmpty) {
      return text;
    }
    final codes = [if (bold) 1, if (dim) 2, if (fg != null) fg.code];
    return codes.isEmpty ? text : '\x1B[${codes.join(';')}m$text\x1B[0m';
  }

  /// Writes [text] and a newline.
  void writeln([String text = '']) => out.writeln(text);

  /// A yellow, bold heading.
  void heading(String text) =>
      out.writeln(style(text, fg: Ansi.yellow, bold: true));

  /// `✔ text` in green.
  void success(String text) =>
      out.writeln('${style(_symbol('✔', '[ok]'), fg: Ansi.green)} $text');

  /// `⚠ text` in yellow.
  void warn(String text) =>
      out.writeln('${style(_symbol('⚠', '[!]'), fg: Ansi.yellow)} $text');

  /// `✖ text` in red, on [err].
  void error(String text) =>
      err.writeln('${style(_symbol('✖', '[x]'), fg: Ansi.red)} $text');

  /// `ℹ text` in cyan.
  void info(String text) =>
      out.writeln('${style(_symbol('ℹ', '[i]'), fg: Ansi.cyan)} $text');

  String _symbol(String utf8, String plain) => unicode ? utf8 : plain;

  /// [lines] in a single-line box (ASCII without UTF-8) as wide as the
  /// longest line, at most the terminal's width and 80 columns.
  void box(List<String> lines, {String? title}) {
    final (h, v, tl, tr, bl, br) = unicode
        ? ('─', '│', '┌', '┐', '└', '┘')
        : ('-', '|', '+', '+', '+', '+');
    final limit = (width < 80 ? width : 80) - 4;
    var inner = [
      for (final line in lines) line.length,
      if (title != null) title.length + 2,
    ].fold(0, (a, b) => a > b ? a : b);
    if (inner > limit) {
      inner = limit;
    }
    final top = title == null
        ? h * (inner + 2)
        : '$h ${style(title, bold: true)} ${h * (inner - title.length - 1)}';
    out.writeln('$tl$top$tr');
    for (final line in lines) {
      final text = line.length > inner ? line.substring(0, inner) : line;
      out.writeln('$v ${text.padRight(inner)} $v');
    }
    out.writeln('$bl${h * (inner + 2)}$br');
  }

  /// A plain table: [header] then [rows], columns padded to their widest
  /// cell.
  void table(List<String> header, List<List<String>> rows) {
    final widths = [
      for (var i = 0; i < header.length; i++)
        [
          header[i].length,
          for (final row in rows)
            if (i < row.length) row[i].length,
        ].fold(0, (a, b) => a > b ? a : b),
    ];
    String line(List<String> cells) => [
      for (var i = 0; i < cells.length; i++)
        i == cells.length - 1 ? cells[i] : cells[i].padRight(widths[i]),
    ].join('  ');
    out.writeln(style(line(header), bold: true));
    for (final row in rows) {
      out.writeln(line(row));
    }
  }

  /// A spinner for [text] until [Spinner.stop]: animated on a terminal,
  /// one line otherwise.
  Spinner spinner(String text) => Spinner._(this, text);
}

/// A running task's line ([Console.spinner]).
final class Spinner {
  Spinner._(this._console, this._text) {
    if (_console.terminal && _console.out == stdout) {
      _timer = Timer.periodic(const Duration(milliseconds: 80), (_) => _draw());
      _draw();
    } else {
      _console.out.writeln('$_text ...');
    }
  }

  final Console _console;
  final String _text;
  Timer? _timer;
  var _frame = 0;

  static const _unicodeFrames = [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];
  static const _plainFrames = ['|', '/', '-', r'\'];

  void _draw() {
    final frames = _console.unicode ? _unicodeFrames : _plainFrames;
    final frame = frames[_frame++ % frames.length];
    stdout.write('\r${_console.style(frame, fg: Ansi.cyan)} $_text');
  }

  /// Ends the spinner with a success or failure line.
  void stop({bool success = true, String? message}) {
    final timer = _timer;
    _timer = null;
    if (timer != null) {
      timer.cancel();
      stdout.write('\r\x1B[2K');
    } else if (message == null) {
      return;
    }
    final text = message ?? _text;
    if (success) {
      _console.success(text);
    } else {
      _console.error(text);
    }
  }
}
