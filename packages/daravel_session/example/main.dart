import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';

/// Counts a visitor's page views in the session; the form posts back with
/// the CSRF token.
Application createApp() => Application.configure(basePath: '.')
    .withSession()
    .withMigrations(const [CreateSessionsTable()])
    .withRouting(
      web: (Router router) => router.group((Router r) {
        r.get('/', (request) {
          final views = request.session.increment('views');
          return Response.html(
            '<p>Views: $views</p>'
            '<form method="post" action="/reset">'
            '<input type="hidden" name="_token" value="${request.session.token}">'
            '<button>Reset</button></form>',
          );
        });
        r.post('/reset', (request) {
          request.session.forget('views');
          return Response.redirect('/');
        });
      }, middleware: const ['web']),
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
