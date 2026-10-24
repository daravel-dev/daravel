/// Built-in code templates (BLUEPRINT_V2 §8.3). Placeholders use
/// `{{ name }}`; `dartisan stub:publish` copies them to `stubs/<name>.stub`
/// where a project can customise them (project stubs win).
library;

/// Renders [template], replacing every `{{ key }}` from [values].
/// Unknown placeholders are left untouched so mistakes stay visible.
String renderStub(String template, Map<String, String> values) =>
    template.replaceAllMapped(
      RegExp(r'\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}'),
      (match) {
        final key = match.group(1)!;
        return values[key] ?? match.group(0)!;
      },
    );

/// Stub name → template.
const Map<String, String> builtInStubs = <String, String>{
  'model': _model,
  'migration': _migration,
  'migration.create': _migrationCreate,
  'migration.update': _migrationUpdate,
  'seeder': _seeder,
  'factory': _factory,
  'controller': _controller,
  'controller.api': _controllerApi,
  'controller.model.api': _controllerModelApi,
  'request': _request,
  'middleware': _middleware,
  'job': _job,
  'policy': _policy,
  'policy.model': _policyModel,
  'event': _event,
  'listener': _listener,
  'listener.event': _listenerEvent,
  'resource': _resource,
  'resource.model': _resourceModel,
  'rule': _rule,
  'observer': _observer,
  'provider': _provider,
  'command': _command,
  'test': _test,
  'test.unit': _testUnit,
};

const String _model = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} extends Model {
  static final ModelDefinition<{{ class }}> definition = ModelDefinition<{{ class }}>(
    table: '{{ table }}',
    factory: {{ class }}.new,
    fillable: [],
    hidden: [],
    casts: {
      'created_at': Cast.dateTime,
      'updated_at': Cast.dateTime,
    },{{ softDeletes }}
  );

  @override
  ModelDefinition<{{ class }}> get modelDefinition => {{ class }}.definition;

  // <dartisan:statics>
  static ModelQuery<{{ class }}> query() => definition.query();
  static Future<{{ class }}?> find(Object id) => query().find(id);
  static Future<{{ class }}> findOrFail(Object id) => query().findOrFail(id);
  static Future<{{ class }}> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<{{ class }}>> all() => query().get();
  static ModelQuery<{{ class }}> where(Object column, [Object? op, Object? value]) =>
      query().where(column, op, value);
  // </dartisan:statics>

  // <dartisan:accessors>
  int get id => getAttr('id');
  DateTime? get createdAt => getAttr('created_at');
  DateTime? get updatedAt => getAttr('updated_at');
  // </dartisan:accessors>
}
''';

const String _migration = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} extends Migration {
  const {{ class }}();

  @override
  String get name => '{{ name }}';

  @override
  Future<void> up(SchemaBuilder schema) async {
    // Schema changes go here.
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    // Reverse the changes made in up().
  }
}
''';

const String _migrationCreate = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} extends Migration {
  const {{ class }}();

  @override
  String get name => '{{ name }}';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('{{ table }}', (table) {
      table.id();
      table.timestamps();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('{{ table }}');
  }
}
''';

const String _migrationUpdate = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} extends Migration {
  const {{ class }}();

  @override
  String get name => '{{ name }}';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.table('{{ table }}', (table) {
      // table.string('column').nullable();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.table('{{ table }}', (table) {
      // table.dropColumn('column');
    });
  }
}
''';

const String _seeder = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} extends Seeder {
  const {{ class }}();

  @override
  Future<void> run() async {
    // Seed the database here.
  }
}
''';

const String _factory = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/{{ modelFile }}.dart';

/// Factory for [{{ model }}].
ModelFactory<{{ model }}> {{ function }}({Faker? faker}) => ModelFactory<{{ model }}>(
  {{ model }}.definition,
  (Faker f) => <String, Object?>{
    // 'name': f.name(),
  },
  faker: faker,
);
''';

const String _controller = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} {
  Future<Object?> index(Request request) async => <String, Object?>{};
}
''';

const String _controllerApi = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} implements ResourceController {
  @override
  Future<Object?> index(Request request) async => <String, Object?>{'data': []};

  @override
  Future<Object?> store(Request request) async {
    final data = await request.validate({});
    return Response.created(data.toMap());
  }

  @override
  Future<Object?> show(Request request) async => <String, Object?>{};

  @override
  Future<Object?> update(Request request) async {
    final data = await request.validate({});
    return data.toMap();
  }

  @override
  Future<Object?> destroy(Request request) async => Response.noContent();
}
''';

const String _controllerModelApi = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/{{ modelFile }}.dart';

/// Register with `router.apiResource('{{ resource }}', {{ class }}())`.
final class {{ class }} implements ResourceController {
  @override
  Future<Object?> index(Request request) => {{ model }}.query().paginate(
    page: int.tryParse(request.query['page'] ?? '') ?? 1,
    path: request.path,
  );

  @override
  Future<Object?> store(Request request) async {
    final data = await request.validate({});
    return {{ model }}.create(data.toMap());
  }

  @override
  Future<Object?> show(Request request) =>
      {{ model }}.findOrFail(request.param<int>('{{ param }}'));

  @override
  Future<Object?> update(Request request) async {
    final model = await {{ model }}.findOrFail(request.param<int>('{{ param }}'));
    final data = await request.validate({});
    await model.update(data.toMap());
    return model;
  }

  @override
  Future<Object?> destroy(Request request) async {
    final model = await {{ model }}.findOrFail(request.param<int>('{{ param }}'));
    await model.delete();
    return Response.noContent();
  }
}
''';

const String _request = r'''
import 'dart:async';

import 'package:daravel/daravel.dart';

final class {{ class }} extends FormRequest {
  const {{ class }}();

  @override
  FutureOr<bool> authorize(Request request) => true;

  @override
  Map<String, Object> rules(Request request) => {
    // 'email': 'required|email',
  };
}
''';

const String _middleware = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} implements Middleware {
  const {{ class }}();

  @override
  Future<Response> handle(Request request, Next next) async {
    final response = await next(request);
    return response;
  }
}
''';

const String _job = r'''
import 'package:daravel/daravel.dart';

/// Queued job; dispatch with `await Queue.dispatch(const {{ class }}())`.
final class {{ class }} extends Job {
  const {{ class }}();

  /// Stable registry key (see bootstrap/jobs.dart).
  static const String name = '{{ jobName }}';

  factory {{ class }}.fromJson(Map<String, Object?> json) => const {{ class }}();

  @override
  String get jobName => name;

  @override
  int get tries => 3;

  @override
  List<Duration> get backoff => const [Duration(seconds: 10), Duration(seconds: 60)];

  @override
  Map<String, Object?> toJson() => const <String, Object?>{};

  @override
  Future<void> handle(JobContext ctx) async {
    // Do the work here.
  }
}
''';

const String _policy = r'''
import 'package:daravel/daravel.dart';

/// Register with `gate.define(...)` or attach to a model type.
final class {{ class }} extends Policy<Object> {
  const {{ class }}();
}
''';

const String _policyModel = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/{{ modelFile }}.dart';

final class {{ class }} extends Policy<{{ model }}> {
  const {{ class }}();

  @override
  Object? viewAny(Authenticatable? user) => true;

  @override
  Object? view(Authenticatable? user, {{ model }} model) => true;

  @override
  Object? create(Authenticatable? user) => user != null;

  @override
  Object? update(Authenticatable? user, {{ model }} model) => false;

  @override
  Object? delete(Authenticatable? user, {{ model }} model) => false;
}
''';

const String _event = r'''
/// Dispatch with `await Event.dispatch({{ class }}(...))`.
final class {{ class }} {
  const {{ class }}();
}
''';

const String _listener = r'''
final class {{ class }} {
  const {{ class }}();

  Future<void> handle(Object event) async {
    // React to the event here.
  }
}
''';

const String _listenerEvent = r'''
import 'package:{{ package }}/app/events/{{ eventFile }}.dart';

/// Wired in bootstrap/listeners.dart.
final class {{ class }} {
  const {{ class }}();

  Future<void> handle({{ event }} event) async {
    // React to the event here.
  }
}
''';

const String _resource = r'''
import 'package:daravel/daravel.dart';

final class {{ class }} extends JsonResource<Map<String, Object?>> {
  {{ class }}(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {...resource};
}
''';

const String _resourceModel = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/{{ modelFile }}.dart';

final class {{ class }} extends JsonResource<{{ model }}> {
  {{ class }}(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'created_at': resource.createdAt?.toIso8601String(),
    'updated_at': resource.updatedAt?.toIso8601String(),
  };
}
''';

const String _rule = r'''
import 'package:daravel/daravel.dart';

/// Use as `[Rules.required(), const {{ class }}()]`.
final class {{ class }} extends Rule {
  const {{ class }}();

  @override
  String get name => '{{ ruleName }}';

  @override
  String? passes(ValidationContext context) {
    final value = context.value;
    return value is String && value.isNotEmpty
        ? null
        : 'The :attribute field is invalid.';
  }
}
''';

const String _observer = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/{{ modelFile }}.dart';

/// Attach with `observers: [const {{ class }}()]` in {{ model }}.definition.
final class {{ class }} extends ModelObserver<{{ model }}> {
  const {{ class }}();

  @override
  bool? created({{ model }} model) => null;

  @override
  bool? updated({{ model }} model) => null;

  @override
  bool? deleted({{ model }} model) => null;
}
''';

const String _provider = r'''
import 'dart:async';

import 'package:daravel/daravel.dart';

/// Register with `.withProviders([const {{ class }}()])`.
final class {{ class }} extends ServiceProvider {
  const {{ class }}();

  @override
  FutureOr<void> register(Container container) {
    // container.singleton<MyService>((c) => MyService());
  }

  @override
  FutureOr<void> boot(Container container) {}
}
''';

const String _command = r'''
import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';

/// `dartisan {{ signature }}` (registered in bootstrap/commands.dart).
final class {{ class }} extends DaravelCommand {
  {{ class }}(super.createApp) {
    argParser.addFlag('dry-run', negatable: false, help: 'Do nothing.');
  }

  @override
  String get name => '{{ signature }}';

  @override
  String get description => 'Command description';

  @override
  Future<int> run() => withApp((app) async {
    stdout.writeln('{{ signature }} done.');
    return 0;
  });
}
''';

const String _test = r'''
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'},
    );
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  });

  tearDown(() => app.shutdown());

  test('{{ description }}', () async {
    (await client.get('/up')).assertOk();
  });
}
''';

const String _testUnit = r'''
import 'package:test/test.dart';

void main() {
  test('{{ description }}', () {
    expect(1 + 1, 2);
  });
}
''';
