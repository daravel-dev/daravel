# HTTP client

`Http` sends outgoing requests to payment gateways, messaging APIs and other
services, with Laravel's `Http::` API. It uses one pooled `dart:io` client per
application, so connections are reused.

```dart
final response = await Http.withToken(apiKey)
    .baseUrl('https://api.example.com')
    .timeout(const Duration(seconds: 10))
    .retry(3, delay: const Duration(milliseconds: 200))
    .acceptJson()
    .post('/v1/charges', json: {'amount': 5000, 'currency': 'idr'});

if (response.successful) {
  final id = response.json('id');        // dot paths: response.json('data.0.id')
}
response.throwIfFailed();                // RequestException on 4xx/5xx
```

- Requests: `get` and `head` (with `query:`), `post`, `put` and `patch` (with
  `json:`, `form:` or a raw `body:`), `delete`.
- Options: `baseUrl`, `withHeaders`, `withToken`, `withBasicAuth`,
  `withUserAgent`, `accept` / `acceptJson`, `asForm` (send `json:` maps as a
  form), `timeout` (30 s by default, as in Laravel: one deadline for
  connecting, sending and reading the whole body; when it passes the
  connection is closed), `maxResponseSize(bytes)` (32 MiB by default,
  `HttpClientFactory.maxResponseBytes`; a larger body throws
  `ResponseTooLargeException` and closes the connection, `null` for no
  limit).
- `retry(times, delay:, when:)` tries up to `times` times when the connection
  fails or the response is 4xx/5xx, or when `when(response, error)` says so,
  and returns the last response. A connection that cannot be made, or a
  timeout, throws `ConnectionException`, TLS failures included.
  As in Laravel, every failed response is retried by default.
  `backoff:` replaces the fixed delay (`Http.exponentialBackoff()`, or
  `Http.backoffSequence([...])` for Laravel's `retry(3, [100, 200])`),
  `jitter:` (0 to 1) spreads the waits, and `when: Http.retryOnConnectionOr5xx`
  (connection errors, 429 and 5xx) or `Http.retryOnConnectionOnly` leaves
  the other client errors alone. `honorRetryAfter: true` waits what a
  `429` or `503` asks in `Retry-After`, at most `maxRetryAfter` (10 s):

  ```dart
  await Http.retry(
    3,
    backoff: Http.exponentialBackoff(),
    jitter: 0.2,
    when: Http.retryOnConnectionOr5xx,
    honorRetryAfter: true,
  ).get(url);
  ```
- Responses: `status`, `body`, `json([path, fallback])`, `jsonMap()`,
  `header(name)`, `successful` (2xx), `ok` (200), `redirect`, `clientError`,
  `serverError`, `failed`, `bodyBytes` (the body as received, for binary
  responses), and `throwIfFailed` / `throwIfClientError` /
  `throwIfServerError`.

## Testing

`Http.fake` answers requests without the network and records them:

```dart
final http = Http.fake({
  'api.example.com/v1/*': Http.response({'id': 'ch_1'}, 201),
  'hooks.example.com/*': Http.sequence([
    Http.response({'error': 'busy'}, 503),
    Http.response({'ok': true}),
  ]),
  'slow.example.com/*': (ClientRequest request) => Http.response('ok'),
});
Http.preventStrayRequests();   // unstubbed URLs throw instead of answering 200

// ... run the code under test ...

http.assertSent((r) => r.url.host == 'api.example.com' && r.json('amount') == 5000);
http.assertSentCount(1);
http.assertNotSent((r) => r.method == 'DELETE');
```

Patterns match like Laravel's: `*` is a wildcard and a missing scheme is
allowed, so `example.com/*` also matches `https://shop.example.com/x`.
Without stubs, every request answers an empty 200.
