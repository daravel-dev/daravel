@Tags(['conformance'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Stamped extends Model {
  static final ModelDefinition<Stamped> definition = ModelDefinition<Stamped>(
    table: 'stamped',
    factory: Stamped.new,
    updatedAt: 'modified_at',
  );

  @override
  ModelDefinition<Stamped> get modelDefinition => Stamped.definition;
}

final class Exam extends Model {
  static final ModelDefinition<Exam> definition = ModelDefinition<Exam>(
    table: 'exams',
    factory: Exam.new,
  );

  @override
  ModelDefinition<Exam> get modelDefinition => Exam.definition;
}

final class Legacy extends Model {
  static final ModelDefinition<Legacy> definition = ModelDefinition<Legacy>(
    table: 'legacies',
    factory: Legacy.new,
    snakeAttributes: false,
  );

  @override
  ModelDefinition<Legacy> get modelDefinition => Legacy.definition;
}

/// `HasAttributes::relationsToArray` and `$snakeAttributes` (laravel/framework
/// 8.x to 13.x): relation keys are `Str::snake`d, attributes are not touched.
void main() {
  tearDown(() => Model.snakeAttributes = true);

  test('relation keys are snake cased, as Str::snake', () {
    final exam = Exam()
      ..setRelation('tipeUjian', null)
      ..setRelation('posts', <Object?>[])
      ..setRelation('userProfileHTML', null);
    expect(exam.toJson().keys, ['tipe_ujian', 'posts', 'user_profile_h_t_m_l']);
  });

  test('nested models too', () {
    final exam = Exam()
      ..setRelation('tipeUjian', Exam()..setRelation('jenisSoal', null));
    expect(exam.toJson(), {
      'tipe_ujian': {'jenis_soal': null},
    });
  });

  test('hidden and visible name the relation as declared', () {
    final exam = Exam()
      ..setRelation('tipeUjian', null)
      ..makeHidden(['tipeUjian']);
    expect(exam.toJson(), isEmpty);
  });

  test('decimal:N, as BigDecimal::toScale(N, HALF_UP)', () {
    String? cast(Object? value, [int places = 2]) =>
        Cast.decimalString(places).get(value) as String?;
    expect(cast(12.5), '12.50');
    expect(cast('12.5'), '12.50');
    expect(cast(12), '12.00');
    expect(cast('12.345'), '12.35');
    expect(cast('-12.345'), '-12.35');
    expect(cast('12.344'), '12.34');
    expect(cast('0.995'), '1.00');
    expect(cast('.5'), '0.50');
    expect(cast('-0.001'), '0.00');
    expect(cast('1.9995', 3), '2.000');
    expect(cast('2.5', 0), '3');
    expect(cast('12345678901234567890.125'), '12345678901234567890.13');
    expect(cast(null), isNull);
    expect(() => cast('abc'), throwsFormatException);
    expect(() => cast(''), throwsFormatException);
  });

  group('the application\'s lines', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_LOCALE': 'id',
            'DB_DATABASE': ':memory:',
          })
          .withTranslations({
            'id': {
              'validation': {'required': ':attribute wajib ada.'},
              'pagination': {'previous': '&laquo; Sebelumnya'},
            },
            'en': {
              'validation': {'email': 'Fallback must not win.'},
              'pagination': {'next': 'Selanjutnya &raquo;'},
            },
          })
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    test('paginator labels are pagination.previous and .next', () async {
      final labels = await app.run(() async {
        final links = LengthAwarePaginator<int>(
          items: const [1],
          total: 1,
          perPage: 15,
          currentPage: 1,
        ).links;
        return [links.first['label'], links.last['label']];
      });
      expect(labels, ['&laquo; Sebelumnya', 'Selanjutnya &raquo;']);
    });

    test('validation lines win over the bundled ones, per locale', () async {
      final errors = await app.run(
        () => Validator(
          {'a': 'x'},
          {'a': 'email', 'b': 'required'},
          locale: 'id',
        ).run(),
      );
      expect(errors, {
        'a': ['Kolom a harus berupa alamat email yang valid.'],
        'b': ['b wajib ada.'],
      });
    });

    test('without a line the English label stays', () async {
      final label = await app.run(() async {
        Lang.setLocale('en');
        return LengthAwarePaginator<int>(
          items: const [1],
          total: 1,
          perPage: 15,
          currentPage: 1,
        ).links.first['label'];
      });
      expect(label, '&laquo; Previous');
    });
  });

  group('a date the driver read as text', () {
    final date = DatabaseDateTime(
      DateTime.utc(2024, 1, 2, 10, 20, 30),
      '2024-01-02 10:20:30',
    );

    Model model(List<String> casts) =>
        Stamped()..forceFill({'seen_at': date, 'created_at': date});

    test('an uncast column keeps it; timestamps are ISO-8601', () {
      expect(model(const []).toJson(), {
        'seen_at': '2024-01-02 10:20:30',
        'created_at': '2024-01-02T10:20:30.000000Z',
      });
      expect(jsonDate(date.plain), '2024-01-02T10:20:30.000000Z');
      // What a resource gets, `{'created_at': model.createdAt}`.
      expect(
        jsonDate(model(const []).getAttr<DateTime>('created_at')),
        '2024-01-02T10:20:30.000000Z',
      );
      expect(
        jsonDate(model(const []).getAttr<DateTime>('seen_at')),
        '2024-01-02 10:20:30',
      );
      expect(date, DateTime.utc(2024, 1, 2, 10, 20, 30));
    });
  });

  test('Clock.nowIn reads the wall clock of an IANA zone', () {
    Clock.travelTo(DateTime.utc(2026, 1, 2, 23, 30));
    addTearDown(Clock.restore);
    final wita = Clock.nowIn('Asia/Makassar');
    expect([wita.day, wita.hour, wita.minute], [3, 7, 30]);
    expect(wita.isAtSameMomentAs(Clock.now()), isTrue);
    expect(jsonDate(wita), '2026-01-02T23:30:00.000000Z');
    expect(() => Clock.nowIn('Mars/Base'), throwsArgumentError);
  });

  test('opting out: for the application or one model', () {
    expect((Legacy()..setRelation('tipeUjian', null)).toJson().keys, [
      'tipeUjian',
    ]);
    Model.snakeAttributes = false;
    expect((Exam()..setRelation('tipeUjian', null)).toJson().keys, [
      'tipeUjian',
    ]);
  });
}
