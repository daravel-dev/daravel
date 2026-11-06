import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ProjectPaths paths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartisan_gen_');
    await File(p.join(root.path, 'pubspec.yaml'))
        .writeAsString('name: demo_app\n');
    await Directory(p.join(root.path, 'bootstrap')).create();
    paths = ProjectPaths.locate(root.path);
  });

  tearDown(() => root.delete(recursive: true));

  test('naming helpers', () {
    expect(Naming.pascal('blog_post'), 'BlogPost');
    expect(Naming.pascal('blogPost'), 'BlogPost');
    expect(Naming.snake('BlogPostCategory'), 'blog_post_category');
    expect(Naming.camel('BlogPost'), 'blogPost');
    expect(Naming.table('Category'), 'categories');
    expect(Naming.table('Address'), 'addresses');
    expect(Naming.table('Day'), 'days');
    // Laravel's rules (Str::plural), not a bare "add s".
    expect(Naming.table('Stimulus'), 'stimuli');
    expect(Naming.table('Curriculum'), 'curricula');
    expect(Naming.table('Criterion'), 'criteria');
    expect(Naming.table('Person'), 'people');
    expect(Naming.table('Quiz'), 'quizzes');
    expect(Naming.table('ExamStimulus'), 'exam_stimuli');
    expect(
      Naming.timestamp(DateTime.utc(2026, 10, 24, 9, 5, 7)),
      '2026_10_24_090507',
    );
  });

  test(
    'locate walks up to the project root and reads the package name',
    () async {
      final nested = await Directory(p.join(root.path, 'lib', 'app'))
          .create(recursive: true);
      expect(ProjectPaths.locate(nested.path).packageName, 'demo_app');
      expect(
        () => ProjectPaths.locate(Directory.systemTemp.path),
        throwsStateError,
      );
    },
  );

  test(
    'registry patcher inserts sorted imports and appends entries idempotently',
    () {
      final base = RegistryPatcher.template(
        header: '// test',
        listType: 'Migration',
        listName: 'migrations',
      );
      final once = RegistryPatcher.patch(
        base,
        importLine: "import 'b.dart';",
        entryLine: '  const B(),',
      )!;
      final twice = RegistryPatcher.patch(
        once,
        importLine: "import 'a.dart';",
        entryLine: '  const A(),',
      )!;
      expect(twice, contains("import 'a.dart';\nimport 'b.dart';"));
      expect(
        twice.indexOf('const B(),'),
        lessThan(twice.indexOf('const A(),')),
      );
      expect(
        RegistryPatcher.patch(
          twice,
          importLine: "import 'a.dart';",
          entryLine: '  const A(),',
        ),
        isNull,
      );
      expect(
        () => RegistryPatcher.patch(
          'no markers',
          importLine: 'x',
          entryLine: 'y',
        ),
        throwsStateError,
      );
    },
  );

  test('make:model --all generates model, migration, factory, seeder, controller and registries', () {
    final gen = Generator(
      paths,
      clock: () => DateTime.utc(2026, 10, 24, 9, 5, 7),
    );
    gen.model('BlogPost', softDeletes: true);
    gen.migration('create_blog_posts_table', create: 'blog_posts');
    gen.factory('BlogPost', model: 'BlogPost');
    gen.seeder('BlogPostSeeder');
    gen.controller('BlogPostController', api: true, model: 'BlogPost');
    gen.request('StoreBlogPost');
    gen.middleware('EnsureAdmin');

    final model = File(p.join(paths.models, 'blog_post.dart'))
        .readAsStringSync();
    expect(model, contains('final class BlogPost extends Model'));
    expect(model, contains("table: 'blog_posts'"));
    expect(model, contains('softDeletes: true'));
    expect(model, contains('// <dartisan:statics>'));

    final migrationFile = File(
      p.join(
        paths.migrations,
        'm_2026_10_24_090507_create_blog_posts_table.dart',
      ),
    );
    expect(migrationFile.existsSync(), isTrue);
    expect(
      migrationFile.readAsStringSync(),
      contains("await schema.create('blog_posts'"),
    );
    final registry = File(paths.migrationsRegistry).readAsStringSync();
    expect(
      registry,
      contains(
        "import '../database/migrations/m_2026_10_24_090507_create_blog_posts_table.dart';",
      ),
    );
    expect(registry, contains('  const CreateBlogPostsTable(),'));

    expect(
      File(p.join(paths.factories, 'blog_post_factory.dart'))
          .readAsStringSync(),
      contains('ModelFactory<BlogPost> blogPostFactory('),
    );
    expect(
      File(paths.seedersRegistry).readAsStringSync(),
      contains('const BlogPostSeeder(),'),
    );
    final controller = File(
      p.join(paths.controllers, 'blog_post_controller.dart'),
    ).readAsStringSync();
    expect(controller, contains('implements ResourceController'));
    expect(
      controller,
      contains("BlogPost.findOrFail(request.param<int>('blog_post'))"),
    );
    expect(
      File(p.join(paths.requests, 'store_blog_post_request.dart'))
          .readAsStringSync(),
      contains('extends FormRequest'),
    );
    expect(
      File(p.join(paths.middleware, 'ensure_admin_middleware.dart'))
          .readAsStringSync(),
      contains('implements Middleware'),
    );
    expect(gen.log.where((e) => !e.skipped).length, 9);
  });

  test('existing files are skipped unless forced; dry-run writes nothing', () {
    final gen = Generator(paths);
    expect(gen.seeder('Demo').skipped, isFalse);
    expect(Generator(paths).seeder('Demo').skipped, isTrue);
    expect(Generator(paths, force: true).seeder('Demo').overwritten, isTrue);

    final dry = Generator(paths, dryRun: true);
    final result = dry.model('Ghost');
    expect(result.skipped, isFalse);
    expect(File(result.path).existsSync(), isFalse);
  });
  test('make:model fills bootstrap/models.dart only when it exists', () {
    Generator(paths).model('Post');
    expect(File(paths.modelsRegistry).existsSync(), isFalse);

    File(paths.modelsRegistry).writeAsStringSync('''
import 'package:daravel/daravel.dart';
// <dartisan:imports>
// </dartisan:imports>

final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
  // <dartisan:entries>
  // </dartisan:entries>
];
''');
    Generator(paths).model('Comment');
    Generator(paths).model('Comment');
    final registry = File(paths.modelsRegistry).readAsStringSync();
    expect(
      registry,
      contains("import 'package:demo_app/app/models/comment.dart';"),
    );
    expect('Comment.definition,'.allMatches(registry), hasLength(1));
    expect(registry, isNot(contains('Post.definition')));
  });

  group('make:job --model', () {
    test('parses Model and Model:field', () {
      final named = JobModelField.tryParse('User:candidate')!;
      expect((named.model, named.field), ('User', 'candidate'));
      final plain = JobModelField.tryParse('blog_post')!;
      expect((plain.model, plain.field), ('BlogPost', 'blogPost'));
      expect(JobModelField.tryParse('User:Candidate'), isNull);
      expect(JobModelField.tryParse('User:a:b'), isNull);
      expect(JobModelField.tryParse('1User'), isNull);
    });

    test('writes ModelRef fields and literal tags without Horizon', () {
      final gen = Generator(paths)
        ..job(
          'SendReminder',
          models: const [JobModelField('User', 'candidate')],
        );
      expect(gen.log.first.skipped, isFalse);
      final source = File(p.join(paths.jobs, 'send_reminder.dart'))
          .readAsStringSync();
      expect(source, _sendReminder);
      expect(
        File(paths.jobsRegistry).readAsStringSync(),
        contains('JobDefinition(SendReminder.name, SendReminder.fromJson),'),
      );
    });

    test(
      'tags with HorizonTags.model when daravel_horizon is a dependency',
      () {
        File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
          'name: demo_app\n'
          'dependencies:\n'
          '  daravel: ^1.27.0\n'
          '  daravel_horizon: ^1.27.0\n',
        );
        Generator(paths).job(
          'ScoreExam',
          models: const [
            JobModelField('User', 'candidate'),
            JobModelField('Exam', 'exam'),
          ],
        );
        final source = File(p.join(paths.jobs, 'score_exam.dart'))
            .readAsStringSync();
        expect(
          source,
          startsWith(
            "import 'package:daravel/daravel.dart';\n"
            "import 'package:daravel_horizon/daravel_horizon.dart';\n"
            "import 'package:demo_app/app/models/exam.dart';\n"
            "import 'package:demo_app/app/models/user.dart';\n",
          ),
        );
        expect(
          source,
          contains(
            '  List<String> get tags => '
            '[HorizonTags.model(candidate), HorizonTags.model(exam)];',
          ),
        );
        expect(
          source,
          contains(
            'const ScoreExam({required this.candidate, required this.exam});',
          ),
        );
        expect(source, isNot(contains("'User:")));
      },
    );

    test('without --model the job stub is unchanged', () {
      Generator(paths).job('Plain');
      final source = File(p.join(paths.jobs, 'plain.dart')).readAsStringSync();
      expect(source, contains('const Plain();'));
      expect(source, isNot(contains('tags')));
    });
  });
}

const String _sendReminder = r'''
import 'package:daravel/daravel.dart';
import 'package:demo_app/app/models/user.dart';

/// Queued job; dispatch with
/// `await Queue.dispatch(SendReminder(candidate: ModelRef.of(user)))`.
final class SendReminder extends Job {
  const SendReminder({required this.candidate});

  /// Stable registry key (see bootstrap/jobs.dart).
  static const String name = 'send-reminder';

  factory SendReminder.fromJson(Map<String, Object?> json) => SendReminder(
    candidate: ModelRef<User>(
      () => User.definition,
      json['candidate']!,
    ),
  );

  /// The [User], saved as its id and loaded fresh when the job runs.
  final ModelRef<User> candidate;

  @override
  String get jobName => name;

  @override
  int get tries => 3;

  @override
  List<Duration> get backoff => const [Duration(seconds: 10), Duration(seconds: 60)];

  @override
  List<String> get tags => ['User:${candidate.id}'];

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'candidate': candidate.toJson(),
  };

  @override
  Future<void> handle(JobContext ctx) async {
    // final user = await candidate.resolve();
    // Do the work here.
  }
}
''';
