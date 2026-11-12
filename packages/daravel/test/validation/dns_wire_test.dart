import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/src/validation/dns.dart';
import 'package:daravel/src/validation/dns_wire.dart';
import 'package:test/test.dart';

/// An answer to [query] with [flags] and MX [records] (preference, exchange
/// labels; the exchange may end in a compression pointer to the question).
Uint8List answer(
  Uint8List query, {
  int flags = 0x8180,
  List<List<int>> records = const [],
  int? count,
}) {
  final out = BytesBuilder()
    ..add([query[0], query[1], flags >> 8, flags & 0xff, 0, 1])
    ..add([0, count ?? records.length, 0, 0, 0, 0])
    ..add(query.sublist(12));
  for (final data in records) {
    out
      ..add([0xc0, 12, 0, 15, 0, 1, 0, 0, 0, 60, 0, data.length])
      ..add(data);
  }
  return out.toBytes();
}

/// MX rdata: preference 10, then [exchange] as wire labels.
List<int> mxData(List<int> exchange) => [0, 10, ...exchange];

List<int> labels(String name) => [
  for (final label in name.split('.')) ...[label.length, ...label.codeUnits],
  0,
];

void main() {
  final query = buildMxQuery(0xbeef, 'example.com');

  test('the query is one MX question with recursion desired', () {
    expect(query.sublist(0, 12), [
      0xbe, 0xef, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, //
    ]);
    expect(query.sublist(12), [
      ...labels('example.com'),
      0, 15, 0, 1, //
    ]);
  });

  MxAnswer parse(Uint8List packet) =>
      parseMxAnswer(packet, id: 0xbeef, name: 'example.com');

  test('reads the MX targets, with a compressed exchange', () {
    final packet = answer(
      query,
      records: [
        mxData(labels('mx1.example.com')),
        // mail + pointer to example.com in the question.
        mxData([4, ...'mail'.codeUnits, 0xc0, 12]),
      ],
    );
    expect(
      parse(packet),
      isA<MxRecords>().having((r) => r.targets, 'targets', [
        'mx1.example.com',
        'mail.example.com',
      ]),
    );
  });

  test('a null MX is the empty target; NXDOMAIN is no MX', () {
    expect(
      (parse(
        answer(
          query,
          records: [
            mxData([0]),
          ],
        ),
      ) as MxRecords).targets,
      [''],
    );
    expect((parse(answer(query, flags: 0x8183)) as MxRecords).targets, isEmpty);
  });

  test('another id, a question, a query packet: not our answer', () {
    expect(
      parseMxAnswer(answer(query), id: 0x1234, name: 'example.com'),
      isA<MxMismatch>(),
    );
    expect(
      parseMxAnswer(answer(query), id: 0xbeef, name: 'example.org'),
      isA<MxMismatch>(),
    );
    expect(parse(query), isA<MxMismatch>());
    expect(parse(Uint8List(5)), isA<MxMismatch>());
  });

  test('truncated (TC) or a server failure: unknown, not an error', () {
    expect(parse(answer(query, flags: 0x8380)), isA<MxUnknown>());
    expect(parse(answer(query, flags: 0x8182)), isA<MxUnknown>());
  });

  test('a record past the end or a pointer loop: unknown', () {
    final cut = answer(query, records: [mxData(labels('mx.example.com'))]);
    expect(
      parse(Uint8List.sublistView(cut, 0, cut.length - 3)),
      isA<MxUnknown>(),
    );
    // The exchange points at itself.
    final loop = answer(
      query,
      records: [
        mxData([0xc0, 0]),
      ],
    );
    final at = loop.length - 2;
    loop[at + 1] = at;
    expect(parse(loop), isA<MxUnknown>());
    expect(readDnsName(loop, at), isNull);
  });

  test('a lying record count is bounded', () {
    final packet = answer(
      query,
      records: [mxData(labels('mx.example.com'))],
      count: 0xff,
    );
    // 255 announced, one present: reading stops at the end, unknown.
    expect(parse(packet), isA<MxUnknown>());
    final many = answer(
      query,
      records: [
        for (var i = 0; i < 100; i++) mxData([0]),
      ],
    );
    expect((parse(many) as MxRecords).targets, hasLength(maxAnswerRecords));
  });

  test('random and mutated packets never throw or hang', () {
    final random = Random(42);
    final valid = answer(
      query,
      records: [
        mxData(labels('mx1.example.com')),
        mxData([4, ...'mail'.codeUnits, 0xc0, 12]),
      ],
    );
    for (var i = 0; i < 20000; i++) {
      final Uint8List packet;
      if (i.isEven) {
        packet = Uint8List.fromList(valid);
        for (var flips = random.nextInt(4) + 1; flips > 0; flips--) {
          packet[random.nextInt(packet.length)] = random.nextInt(256);
        }
      } else {
        packet = Uint8List.fromList([
          0xbe,
          0xef,
          for (var j = random.nextInt(80); j > 0; j--) random.nextInt(256),
        ]);
      }
      final cut = Uint8List.sublistView(
        packet,
        0,
        random.nextInt(packet.length + 1),
      );
      expect(() => parse(cut), returnsNormally);
    }
  });

  group('names', () {
    test('punycode as RFC 3492 and idn_to_ascii', () {
      expect(punycode('bücher'), 'bcher-kva');
      expect(punycode('münchen'), 'mnchen-3ya');
      expect(punycode('例え'), 'r8jz45g');
      expect(toAsciiHost('BÜCHER.example.'), 'xn--bcher-kva.example');
      expect(toAsciiHost('例え.テスト'), 'xn--r8jz45g.xn--zckzah');
    });

    test('the sample strings of RFC 3492 §7.1', () {
      // Code points as the RFC lists them; ASCII keeps its case.
      final samples = <List<int>, String>{
        // (A) Arabic (Egyptian).
        [
          0x0644, 0x064A, 0x0647, 0x0645, 0x0627, 0x0628, 0x062A, 0x0643, //
          0x0644, 0x0645, 0x0648, 0x0634, 0x0639, 0x0631, 0x0628, 0x064A,
          0x061F,
        ]: 'egbpdaj6bu4bxfgehfvwxn',
        // (B) Chinese (simplified).
        [
          0x4ED6, 0x4EEC, 0x4E3A, 0x4EC0, 0x4E48, 0x4E0D, 0x8BF4, 0x4E2D, //
          0x6587,
        ]: 'ihqwcrb4cv8a8dqg056pqjye',
        // (C) Chinese (traditional).
        [
          0x4ED6, 0x5011, 0x7232, 0x4EC0, 0x9EBD, 0x4E0D, 0x8AAA, 0x4E2D, //
          0x6587,
        ]: 'ihqwctvzc91f659drss3x8bo0yb',
        // (L) 3<nen>B<gumi><kinpachi><sensei>.
        [0x0033, 0x5E74, 0x0042, 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F]:
            '3B-ww4c5e180e575a65lsy2b',
        // (M) <amuro><namie>-with-SUPER-MONKEYS.
        [
          0x5B89, 0x5BA4, 0x5948, 0x7F8E, 0x6075, //
          ...'-with-SUPER-MONKEYS'.codeUnits,
        ]: '-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n',
        // (R) <sono><supiido><de>.
        [0x305D, 0x306E, 0x30B9, 0x30D4, 0x30FC, 0x30C9, 0x3067]:
            'd9juau41awczczp',
        // (S) -> $1.00 <- (all basic code points).
        '-> \$1.00 <-'.codeUnits: '-> \$1.00 <--',
      };
      for (final MapEntry(key: points, value: encoded) in samples.entries) {
        expect(punycode(String.fromCharCodes(points)), encoded);
      }
    });

    test('a name DNS cannot carry is refused', () {
      expect(toAsciiHost(''), isNull);
      expect(toAsciiHost('a..b'), isNull);
      expect(toAsciiHost('${'a' * 64}.com'), isNull);
      expect(toAsciiHost(List.filled(130, 'ab').join('.')), isNull);
    });

    test('IP literals', () {
      for (final ip in ['127.0.0.1', '::1', '[::1]', '[2001:db8::1]']) {
        expect(isIpLiteral(ip), isTrue, reason: ip);
      }
      expect(isIpLiteral('example.com'), isFalse);
      expect(isIpLiteral('1.2.3.4.example'), isFalse);
    });
  });
}
