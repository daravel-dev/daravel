import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';

/// A model whose score and status changes are logged.
final class Assessment extends Model with LogsActivity {
  static final ModelDefinition<Assessment> definition =
      ModelDefinition<Assessment>(
        table: 'assessments',
        factory: Assessment.new,
        fillable: ['title', 'score', 'status'],
        observers: [ActivityLogObserver<Assessment>()],
      );

  @override
  ModelDefinition<Assessment> get modelDefinition => Assessment.definition;

  @override
  LogOptions get activitylogOptions => LogOptions.defaults()
      .logOnly(['score', 'status'])
      .logOnlyDirty()
      .dontSubmitEmptyLogs();
}

/// Serves an application whose `GET /assessments/{id}/history` lists the
/// changes of an assessment.
Application createApp() => Application.configure(basePath: '.')
    .withActivityLog()
    .withMigrations(const [CreateActivityLogTable()])
    .withModels([Assessment.definition])
    .withRouting(
      api: (router) =>
          router.get('/assessments/{id}/history', (Request request) async {
            final assessment = await Assessment.definition.query().findOrFail(
              int.parse(request.routeParams['id']!),
            );
            return [
              for (final entry in await assessment.activities().latest().get())
                {'event': entry.event, ...entry.changes},
            ];
          }),
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
