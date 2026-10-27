import 'dart:convert';

import 'package:daravel_s3/daravel_s3.dart';
import 'package:test/test.dart';

/// AWS's published S3 SigV4 examples: "Signature Calculations for the
/// Authorization Header: Transferring Payload in a Single Chunk" and
/// "Authenticating Requests: Using Query Parameters" (Amazon S3 API
/// Reference), all with the documentation's example credentials.
void main() {
  const signer = SigV4Signer(
    accessKey: 'AKIAIOSFODNN7EXAMPLE',
    secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    region: 'us-east-1',
  );
  final now = DateTime.utc(2013, 5, 24);
  final client = S3Client(
    signer: signer,
    bucket: 'examplebucket',
    endpoint: 'https://s3.amazonaws.com',
  );

  String signatureOf(Map<String, String> headers) =>
      RegExp('Signature=([0-9a-f]{64})')
          .firstMatch(headers['authorization']!)!
          .group(1)!;

  test('GET Object with a Range header', () {
    final headers = signer.sign(
      method: 'GET',
      uri: client.uri('test.txt'),
      now: now,
      headers: {'Range': 'bytes=0-9'},
    );
    expect(
      headers['authorization'],
      startsWith(
        'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/'
        's3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;'
        'x-amz-date, ',
      ),
    );
    expect(
      signatureOf(headers),
      'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
    );
  });

  test(r'PUT Object with a $ in the key and extra signed headers', () {
    final uri = client.uri(r'test$file.text');
    expect(
      uri.toString(),
      'https://examplebucket.s3.amazonaws.com/test%24file.text',
    );
    final headers = signer.sign(
      method: 'PUT',
      uri: uri,
      now: now,
      headers: {
        'Date': 'Fri, 24 May 2013 00:00:00 GMT',
        'x-amz-storage-class': 'REDUCED_REDUNDANCY',
      },
      payload: payloadHash(utf8.encode('Welcome to Amazon S3.')),
    );
    expect(
      headers['x-amz-content-sha256'],
      '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
    );
    expect(
      signatureOf(headers),
      '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
    );
  });

  test('GET Bucket lifecycle (a value-less query parameter)', () {
    final headers = signer.sign(
      method: 'GET',
      uri: client.uri('', {'lifecycle': ''}),
      now: now,
    );
    expect(
      signatureOf(headers),
      'fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543',
    );
  });

  test('GET Bucket (list objects) with sorted query parameters', () {
    final headers = signer.sign(
      method: 'GET',
      uri: client.uri('', {'prefix': 'J', 'max-keys': '2'}),
      now: now,
    );
    expect(
      signatureOf(headers),
      '34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7',
    );
  });

  test('presigned GET valid for a day', () {
    final url = signer.presign(
      method: 'GET',
      uri: client.uri('test.txt'),
      now: now,
      expires: const Duration(days: 1),
    );
    expect(
      url.toString(),
      'https://examplebucket.s3.amazonaws.com/test.txt'
      '?X-Amz-Algorithm=AWS4-HMAC-SHA256'
      '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request'
      '&X-Amz-Date=20130524T000000Z'
      '&X-Amz-Expires=86400'
      '&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404'
      '&X-Amz-SignedHeaders=host',
    );
  });

  test('presigning rejects lifetimes S3 does not accept', () {
    for (final expires in [Duration.zero, const Duration(days: 8)]) {
      expect(
        () => signer.presign(
          method: 'GET',
          uri: client.uri('a'),
          now: now,
          expires: expires,
        ),
        throwsArgumentError,
      );
    }
  });

  test('a session token is signed', () {
    const temporary = SigV4Signer(
      accessKey: 'AKID',
      secretKey: 'secret',
      region: 'us-east-1',
      sessionToken: 'token/with+chars',
    );
    final headers = temporary.sign(
      method: 'GET',
      uri: client.uri('a'),
      now: now,
    );
    expect(headers['x-amz-security-token'], 'token/with+chars');
    expect(headers['authorization'], contains('x-amz-security-token'));
    final url = temporary.presign(
      method: 'GET',
      uri: client.uri('a'),
      now: now,
      expires: const Duration(minutes: 1),
    );
    expect(url.queryParameters['X-Amz-Security-Token'], 'token/with+chars');
  });

  test('awsUriEncode leaves only unreserved characters', () {
    expect(
      awsUriEncode("a b/c~d_e.f-g!*'()ü"),
      'a%20b%2Fc~d_e.f-g%21%2A%27%28%29%C3%BC',
    );
    expect(awsUriEncode('a b/c', keepSlash: true), 'a%20b/c');
  });

  test('virtual-hosted and path-style URLs', () {
    final aws = S3Client(
      signer: const SigV4Signer(
        accessKey: 'a',
        secretKey: 'b',
        region: 'ap-southeast-1',
      ),
      bucket: 'files',
    );
    expect(
      aws.uri('x/y.png').toString(),
      'https://files.s3.ap-southeast-1.amazonaws.com/x/y.png',
    );
    final minio = S3Client(
      signer: signer,
      bucket: 'files',
      endpoint: 'http://127.0.0.1:9000',
      pathStyle: true,
    );
    expect(
      minio.uri('x/y.png').toString(),
      'http://127.0.0.1:9000/files/x/y.png',
    );
    expect(
      minio.uri('', {'list-type': '2'}).toString(),
      'http://127.0.0.1:9000/files?list-type=2',
    );
  });
}
