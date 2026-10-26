<!-- source: http-client.md sha256:c3a9bdc3aa6c -->
# HTTP client

`Http` mengirim request keluar ke payment gateway, API pesan, dan layanan
lain, dengan API `Http::` dari Laravel. `Http` memakai satu client `dart:io`
per aplikasi dengan pool koneksi, sehingga koneksi dipakai ulang.

```dart
final response = await Http.withToken(apiKey)
    .baseUrl('https://api.example.com')
    .timeout(const Duration(seconds: 10))
    .retry(3, delay: const Duration(milliseconds: 200))
    .acceptJson()
    .post('/v1/charges', json: {'amount': 5000, 'currency': 'idr'});

if (response.successful) {
  final id = response.json('id');        // path bertitik: response.json('data.0.id')
}
response.throwIfFailed();                // RequestException pada 4xx/5xx
```

- Request: `get` dan `head` (dengan `query:`), `post`, `put`, dan `patch`
  (dengan `json:`, `form:`, atau `body:` mentah), `delete`.
- Opsi: `baseUrl`, `withHeaders`, `withToken`, `withBasicAuth`,
  `withUserAgent`, `accept` / `acceptJson`, `asForm` (mengirim map `json:`
  sebagai form), `timeout` (default 30 detik, seperti di Laravel).
- `retry(times, delay:, when:)` mencoba hingga `times` kali bila koneksi
  gagal atau respons 4xx/5xx, atau bila `when(response, error)`
  menghendakinya, lalu mengembalikan respons terakhir. Koneksi yang tidak
  bisa dibuat, atau timeout, melempar `ConnectionException`.
- Respons: `status`, `body`, `json([path, fallback])`, `jsonMap()`,
  `header(name)`, `successful` (2xx), `ok` (200), `redirect`, `clientError`,
  `serverError`, `failed`, serta `throwIfFailed` / `throwIfClientError` /
  `throwIfServerError`.

## Testing

`Http.fake` menjawab request tanpa jaringan dan merekamnya:

```dart
final http = Http.fake({
  'api.example.com/v1/*': Http.response({'id': 'ch_1'}, 201),
  'hooks.example.com/*': Http.sequence([
    Http.response({'error': 'busy'}, 503),
    Http.response({'ok': true}),
  ]),
  'slow.example.com/*': (ClientRequest request) => Http.response('ok'),
});
Http.preventStrayRequests();   // URL tanpa stub melempar exception, bukan menjawab 200

// ... jalankan kode yang diuji ...

http.assertSent((r) => r.url.host == 'api.example.com' && r.json('amount') == 5000);
http.assertSentCount(1);
http.assertNotSent((r) => r.method == 'DELETE');
```

Pola dicocokkan seperti di Laravel: `*` adalah wildcard dan scheme boleh
tidak ditulis, jadi `example.com/*` juga cocok dengan
`https://shop.example.com/x`. Tanpa stub, setiap request menjawab 200
kosong.
