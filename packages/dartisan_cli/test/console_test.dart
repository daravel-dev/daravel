import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

void main() {
  group('Console.colorFor (ADR-036 order)', () {
    bool decide({
      bool noColor = false,
      bool ansi = false,
      Map<String, String> env = const {},
      bool terminal = true,
      bool supports = true,
    }) => Console.colorFor(
      noColorFlag: noColor,
      ansiFlag: ansi,
      environment: env,
      hasTerminal: terminal,
      supportsAnsi: supports,
    );

    test('a terminal that takes ANSI escapes is coloured', () {
      expect(decide(), isTrue);
      expect(decide(terminal: false), isFalse, reason: 'a pipe');
      expect(decide(supports: false), isFalse);
    });

    test('NO_COLOR, DARTISAN_NO_COLOR=1 and TERM=dumb win over a terminal', () {
      expect(decide(env: {'NO_COLOR': '1'}), isFalse);
      expect(decide(env: {'NO_COLOR': ''}), isTrue, reason: 'empty is unset');
      expect(decide(env: {'DARTISAN_NO_COLOR': '1'}), isFalse);
      expect(decide(env: {'TERM': 'dumb'}), isFalse);
    });

    test('--ansi forces colour; --no-color wins over everything', () {
      expect(decide(ansi: true, terminal: false), isTrue);
      expect(decide(ansi: true, env: {'NO_COLOR': '1'}), isTrue);
      expect(decide(noColor: true, ansi: true), isFalse);
    });
  });

  test('without colour, text is as written', () {
    final out = StringBuffer();
    final console = Console(out: out, color: false, unicode: true);
    expect(console.style('x', fg: Ansi.green, bold: true), 'x');
    console.success('done');
    expect(out.toString(), '✔ done\n');
  });

  test('colours are SGR codes, reset after the text', () {
    final console = Console(out: StringBuffer(), color: true);
    expect(console.style('x', fg: Ansi.green), '\x1B[32mx\x1B[0m');
    expect(
      console.style('x', bold: true, fg: Ansi.yellow),
      '\x1B[1;33mx\x1B[0m',
    );
    expect(console.style('x', dim: true), '\x1B[2mx\x1B[0m');
  });

  test('symbols fall back to ASCII without UTF-8; errors go to err', () {
    final out = StringBuffer();
    final err = StringBuffer();
    Console(out: out, err: err, color: false, unicode: false)
      ..success('a')
      ..warn('b')
      ..info('c')
      ..error('d');
    expect(out.toString(), '[ok] a\n[!] b\n[i] c\n');
    expect(err.toString(), '[x] d\n');
  });

  test('box and table', () {
    final out = StringBuffer();
    Console(out: out, color: false, unicode: false, width: 120)
      ..box(['one', 'three'], title: 'Hi')
      ..table(
        ['Name', 'Value'],
        [
          ['a', '1'],
          ['long', '2'],
        ],
      );
    expect(out.toString(), '''
+- Hi --+
| one   |
| three |
+-------+
Name  Value
a     1
long  2
''');
  });

  test('a spinner off a terminal writes one line, then its result', () {
    final out = StringBuffer();
    Console(
      out: out,
      color: false,
      unicode: false,
      terminal: false,
    ).spinner('Fetching').stop(message: 'Fetched');
    expect(out.toString(), 'Fetching ...\n[ok] Fetched\n');
  });
}
