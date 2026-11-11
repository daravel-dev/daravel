import '../http/headers.dart';
import '../http/request.dart';
import '../http/response.dart';

/// The request headers htmx sends (htmx.org/reference/#request_headers).
extension HtmxRequest on Request {
  /// Whether htmx sent the request (`HX-Request: true`).
  bool get isHtmx => header('hx-request') == 'true';

  /// Whether it came from an `hx-boost`ed link or form (`HX-Boosted: true`).
  bool get isHtmxBoosted => header('hx-boosted') == 'true';

  /// The `id` of the element htmx swaps the response into (`HX-Target`).
  String? get htmxTarget => header('hx-target');

  /// The `id` of the element that triggered the request (`HX-Trigger`).
  String? get htmxTrigger => header('hx-trigger');
}

/// A redirect to [location] that htmx follows as a page navigation.
///
/// The browser follows a `302` inside htmx's request, and htmx then swaps
/// the page it lands on into the target element. For an htmx request this
/// answers `200` with `HX-Redirect: location` instead, which makes htmx load
/// [location] as a full page; any other request gets an ordinary redirect
/// with [status] (use `303` after a `PUT`, `PATCH` or `DELETE`).
Response htmxRedirect(Request request, String location, {int status = 302}) =>
    request.isHtmx
    ? Response(headers: Headers(<String, Object>{'hx-redirect': location}))
    : Response.redirect(location, status: status);
