import 'dart:math';

import '../../foundation/clock.dart';

/// Minimal, dependency-free fake data generator for seeders and factories.
/// Deterministic when constructed with a [seed] (`Faker(seed: 42)`).
final class Faker {
  Faker({int? seed}) : _random = seed == null ? Random() : Random(seed);

  final Random _random;
  int _uniqueCounter = 0;

  static const List<String> _firstNames = [
    'Ana',
    'Budi',
    'Citra',
    'Dewi',
    'Eka',
    'Fajar',
    'Gita',
    'Hadi',
    'Indah',
    'Joko',
    'Kartika',
    'Lukman',
    'Maya',
    'Nadia',
    'Omar',
    'Putri',
    'Rizky',
    'Sari',
    'Tono',
    'Wayan',
    'Alice',
    'Bob',
    'Carlos',
    'Diana',
    'Ethan',
    'Fiona',
    'George',
    'Hannah',
    'Ivan',
    'Julia',
  ];
  static const List<String> _lastNames = [
    'Pratama',
    'Santoso',
    'Wijaya',
    'Kusuma',
    'Saputra',
    'Lestari',
    'Hidayat',
    'Nugroho',
    'Permata',
    'Setiawan',
    'Smith',
    'Johnson',
    'Garcia',
    'Miller',
    'Davis',
    'Martinez',
    'Lopez',
    'Wilson',
    'Anderson',
    'Taylor',
  ];
  static const List<String> _words = [
    'lorem',
    'ipsum',
    'dolor',
    'sit',
    'amet',
    'consectetur',
    'adipiscing',
    'elit',
    'sed',
    'do',
    'eiusmod',
    'tempor',
    'incididunt',
    'ut',
    'labore',
    'et',
    'dolore',
    'magna',
    'aliqua',
    'enim',
    'ad',
    'minim',
    'veniam',
    'quis',
    'nostrud',
    'exercitation',
    'ullamco',
    'laboris',
    'nisi',
    'aliquip',
    'ex',
    'ea',
    'commodo',
    'consequat',
  ];
  static const List<String> _cities = [
    'Denpasar',
    'Jakarta',
    'Bandung',
    'Surabaya',
    'Yogyakarta',
    'Makassar',
    'Medan',
    'Semarang',
    'Singaraja',
    'Ubud',
  ];
  static const List<String> _domains = [
    'example.com',
    'example.net',
    'example.org',
    'mail.test',
  ];
  static const List<String> _tlds = ['com', 'id', 'net', 'org', 'dev'];

  // --- primitives -------------------------------------------------------------

  /// Random integer in `[min, max]`.
  int integer({int min = 0, int max = 1000}) =>
      min + _random.nextInt(max - min + 1);

  /// Random double in `[min, max)` rounded to [decimals].
  double decimal({double min = 0, double max = 1000, int decimals = 2}) {
    final value = min + _random.nextDouble() * (max - min);
    final factor = pow(10, decimals);
    return (value * factor).round() / factor;
  }

  /// `true` with probability [chance] (0–100).
  bool boolean([int chance = 50]) => _random.nextInt(100) < chance;

  /// A random element of [items].
  T pick<T>(List<T> items) => items[_random.nextInt(items.length)];

  /// [count] distinct random elements of [items].
  List<T> pickMany<T>(List<T> items, int count) {
    final copy = List<T>.of(items)..shuffle(_random);
    return copy.take(count).toList();
  }

  /// Monotonic counter for unique values.
  int unique() => ++_uniqueCounter;

  // --- people -----------------------------------------------------------------

  String firstName() => pick(_firstNames);
  String lastName() => pick(_lastNames);
  String name() => '${firstName()} ${lastName()}';

  /// Unique-ish lowercase username.
  String userName() =>
      '${firstName().toLowerCase()}${lastName().toLowerCase()}${unique()}';

  /// Unique email address on an example domain.
  String email() => '${userName()}@${pick(_domains)}';

  /// Indonesian-style mobile number.
  String phone() =>
      '08${integer(min: 11, max: 99)}${integer(min: 10000000, max: 99999999)}';

  // --- text -------------------------------------------------------------------

  String word() => pick(_words);

  List<String> words([int count = 3]) => List.generate(count, (_) => word());

  String sentence([int words = 8]) {
    final text = this.words(words).join(' ');
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }

  String paragraph([int sentences = 3]) =>
      List.generate(sentences, (_) => sentence()).join(' ');

  /// Lorem text of roughly [length] characters.
  String text([int length = 200]) {
    final buffer = StringBuffer();
    while (buffer.length < length) {
      buffer.write('${sentence()} ');
    }
    return buffer.toString().substring(0, length).trimRight();
  }

  String slug([int words = 3]) => this.words(words).join('-');

  String title([int words = 4]) => this
      .words(words)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  // --- misc -------------------------------------------------------------------

  String city() => pick(_cities);

  String company() =>
      '${lastName()} ${pick(const ['Group', 'Labs', 'Studio', 'Corp', 'Co'])}';

  String url() => 'https://${word()}${unique()}.${pick(_tlds)}';

  /// RFC 4122 v4 UUID from this generator's randomness (deterministic with a seed).
  String uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Random instant between [start] and [end].
  DateTime dateTimeBetween(DateTime start, DateTime end) {
    final span = end.difference(start).inSeconds;
    return start.add(Duration(seconds: span <= 0 ? 0 : _random.nextInt(span)));
  }

  DateTime pastDate({int days = 365}) => dateTimeBetween(
    Clock.now().toUtc().subtract(Duration(days: days)),
    Clock.now().toUtc(),
  );

  DateTime futureDate({int days = 365}) => dateTimeBetween(
    Clock.now().toUtc(),
    Clock.now().toUtc().add(Duration(days: days)),
  );

  /// Random string of [length] chars from [alphabet].
  String randomString(
    int length, {
    String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789',
  }) => List.generate(
    length,
    (_) => alphabet[_random.nextInt(alphabet.length)],
  ).join();
}
