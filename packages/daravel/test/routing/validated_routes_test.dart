import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class SaveNoteRequest extends FormRequest<SaveNoteInput> {
  const SaveNoteRequest();

  static const title = Field<String>('title');
  static const stars = Field<int?>('stars');

  @override
  bool authorize(Request request) => request.header('x-deny') == null;

  @override
  Map<String, Object> rules(Request request) => {
    title: [Rules.required(), Rules.string()],
    stars: [Rules.nullable(), Rules.integer()],
  };
}

extension type const SaveNoteInput(ValidatedData _data)
    implements ValidatedData {
  String get title => _data.field(SaveNoteRequest.title);
  int? get stars => _data.field(SaveNoteRequest.stars);
}

/// `Router.postValidated` and its relatives (W9.5): the form request runs
/// before the handler (403, 422), the handler gets the typed input, and
/// the route carries the form for OpenAPI as `.validates` does.
void main() {
  late Application app;
  late RouteEntry posted;

  Future<Object?> echo(Request request, SaveNoteInput data) async =>
      <String, Object?>{
        'method': request.method,
        'title': data.title,
        'stars': data.stars,
      };

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          api: (r) {
            posted = r.postValidated('/notes', const SaveNoteRequest(), echo);
            r.putValidated('/notes/1', const SaveNoteRequest(), echo);
            r.patchValidated('/notes/1', const SaveNoteRequest(), echo);
            r.deleteValidated('/notes/1', const SaveNoteRequest(), echo);
          },
        )
        .create();
    await app.boot();
  });

  tearDown(() => app.shutdown());

  Future<HttpResponseLike> send(
    String method, {
    Map<String, Object?> json = const {'title': 'Hi', 'stars': '4'},
    Map<String, String>? headers,
  }) async {
    final response = await app.handle(
      Request.fake(
        method: method,
        path: method == 'POST' ? '/api/notes' : '/api/notes/1',
        json: json,
        headers: headers,
      ),
    );
    return (status: response.status, body: await response.bodyText());
  }

  test('every verb hands the handler the typed input', () async {
    for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
      final ok = await send(method);
      expect(ok.status, 200, reason: method);
      expect(ok.body, '{"method":"$method","title":"Hi","stars":4}');
    }
  });

  test('the form request answers 422 and 403 before the handler', () async {
    final invalid = await send('POST', json: {'title': ''});
    expect(invalid.status, 422);
    expect(invalid.body, contains('The title field is required.'));
    final forbidden = await send('POST', headers: {'x-deny': '1'});
    expect(forbidden.status, 403);
  });

  test('the route carries its form request, as .validates does', () {
    expect(posted.formRequest, isA<SaveNoteRequest>());
  });
}

typedef HttpResponseLike = ({int status, String body});
