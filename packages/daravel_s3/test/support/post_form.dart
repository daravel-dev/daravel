import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Sends [fields] and then [file] as `multipart/form-data` to [url], as a
/// browser submits an S3 POST form (`file` last).
Future<({int status, String body})> postForm(
  String url,
  Map<String, String> fields,
  List<int> file, {
  String filename = 'upload.bin',
  String fileType = 'application/octet-stream',
}) async {
  const boundary = '----daravel-s3-test-boundary';
  final body = BytesBuilder(copy: false);
  void text(String value) => body.add(utf8.encode(value));
  for (final MapEntry(:key, :value) in fields.entries) {
    text('--$boundary\r\n');
    text('Content-Disposition: form-data; name="$key"\r\n\r\n');
    text('$value\r\n');
  }
  text('--$boundary\r\n');
  text('Content-Disposition: form-data; name="file"; filename="$filename"\r\n');
  text('Content-Type: $fileType\r\n\r\n');
  body.add(file);
  text('\r\n--$boundary--\r\n');
  final bytes = body.takeBytes();

  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set(
      'content-type',
      'multipart/form-data; boundary=$boundary',
    );
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}
