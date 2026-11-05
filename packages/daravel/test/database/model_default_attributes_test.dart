import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `ModelDefinition(attributes:)`, Laravel's `protected $attributes`.
final class Exam extends Model {
  static final ModelDefinition<Exam> definition = ModelDefinition<Exam>(
    table: 'exams',
    factory: Exam.new,
    fillable: const ['title', 'duration_mode'],
    timestamps: false,
    casts: {'shuffle': Cast.boolean},
    attributes: const {'duration_mode': 'fixed', 'shuffle': 1},
  );
  @override
  ModelDefinition<Exam> get modelDefinition => definition;

  String get title => getAttr('title');
  String get durationMode => getAttr('duration_mode');
  bool get shuffle => getAttr('shuffle');
}

void main() {
  late Directory base;
  late Application app;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_model_defaults');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    await app.run(
      () => DB.statement(
        "CREATE TABLE exams (id INTEGER PRIMARY KEY, title TEXT NOT NULL, "
        "duration_mode TEXT NOT NULL DEFAULT 'fixed', "
        'shuffle INTEGER NOT NULL DEFAULT 0)',
      ),
    );
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test('a new model starts with the defaults, clean', () {
    final exam = Exam();
    expect(exam.durationMode, 'fixed');
    expect(exam.shuffle, isTrue);
    expect(exam.isDirty(), isFalse);
    exam.setAttr('title', 'Math');
    expect(exam.getDirty(), {'title': 'Math'});
  });

  test('create() inserts the defaults and reads them without a reload', () {
    return app.run(() async {
      final exam = await Exam.definition.query().create({'title': 'Math'});
      expect(exam.durationMode, 'fixed');
      expect(exam.shuffle, isTrue);
      final row = await DB.table('exams').where('id', exam.key).first();
      expect(row!['shuffle'], 1, reason: 'the default is inserted');
    });
  });

  test('given attributes win over the defaults', () {
    return app.run(() async {
      final exam = await Exam.definition.query().create({
        'title': 'Math',
        'duration_mode': 'per_item',
      });
      expect(exam.durationMode, 'per_item');
    });
  });

  test('a loaded model takes its row, not the defaults', () {
    return app.run(() async {
      await DB.table('exams').insert({
        'title': 'Physics',
        'duration_mode': 'open',
        'shuffle': 0,
      });
      final exam = (await Exam.definition.query().first())!;
      expect(exam.durationMode, 'open');
      expect(exam.shuffle, isFalse);
      final partial = (await Exam.definition.query().select([
        'id',
        'title',
      ]).first())!;
      expect(partial.attributes.containsKey('duration_mode'), isFalse);
    });
  });
}
