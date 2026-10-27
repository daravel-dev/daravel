import 'package:daravel/daravel.dart';
import 'package:daravel_s3/daravel_s3.dart';

/// Files on the bucket of `AWS_*` in `.env`: `POST /api/recordings` stores
/// an upload (multipart above 8 MiB), `GET /api/recordings/{id}` hands out
/// a 30-minute download link, and `POST /api/uploads` gives a browser a
/// form to send up to 500 MB of video straight to the bucket.
Application createApp() =>
    Application.configure(basePath: '.')
        .withS3()
        .withRouting(
          api: (router) {
            router.post('/recordings', (request) async {
              final video = await request.file('video');
              if (video == null) {
                return Response.json({'message': 'No video.'}, status: 422);
              }
              return {'path': await video.store('recordings', disk: 's3')};
            });
            router.get('/recordings/{id}', (request) async {
              final path = 'recordings/${request.param<String>('id')}';
              return {
                'url': Storage.disk('s3')
                    .temporaryUrl(path, expiration: 30.minutes.fromNow),
              };
            });
            router.post('/uploads', (request) async {
              final path = 'materials/${Str.uuid()}.mp4';
              final form = Storage.disk('s3').temporaryUploadForm(
                path,
                expiration: 15.minutes.fromNow,
                maxSize: 500 * 1024 * 1024,
                contentTypePrefix: 'video/',
              );
              return {'path': path, ...form.toJson()}; // method, url, fields
            });
          },
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
