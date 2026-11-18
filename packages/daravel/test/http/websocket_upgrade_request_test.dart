import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  final cases = <(String, String, List<String>, List<String>, bool)>[
    ('one token', 'GET', ['websocket'], ['upgrade'], true),
    ('mixed case', 'GET', ['WebSocket'], ['UpGrAdE'], true),
    ('token list', 'GET', ['websocket'], ['keep-alive, upgrade'], true),
    ('repeated lines', 'GET', ['websocket'], ['keep-alive', 'upgrade'], true),
    ('token boundaries', 'GET', ['websocket'], ['notupgrade'], false),
    (
      'one upgrade value',
      'GET',
      ['websocket', 'websocket'],
      ['upgrade'],
      false,
    ),
    ('GET method', 'POST', ['websocket'], ['upgrade'], false),
    ('HEAD method', 'HEAD', ['websocket'], ['upgrade'], false),
    ('no upgrade', 'GET', [], ['upgrade'], false),
    ('no connection', 'GET', ['websocket'], [], false),
  ];
  for (final (name, method, upgrades, connections, expected) in cases) {
    test(name, () {
      final request = Request.fake(method: method);
      for (final value in upgrades) {
        request.headers.add('upgrade', value);
      }
      for (final value in connections) {
        request.headers.add('connection', value);
      }
      expect(isWebSocketUpgrade(request), expected);
    });
  }
}
