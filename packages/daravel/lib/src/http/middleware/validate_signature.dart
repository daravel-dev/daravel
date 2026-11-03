import '../../routing/url_signer.dart';
import '../http_exceptions.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Rejects requests whose URL signature is missing, invalid or expired
/// (`signed` middleware alias; Laravel `ValidateSignature`).
final class ValidateSignatureMiddleware implements Middleware {
  /// Refuses with 403 a request whose URL [signer] did not sign, or whose
  /// signature expired (Laravel's `signed` middleware).
  const ValidateSignatureMiddleware(this.signer);

  /// Checks the signatures.
  final UrlSigner signer;

  @override
  Future<Response> handle(Request request, Next next) {
    if (!signer.verify(request.uri, host: request.signedHost)) {
      throw const ForbiddenHttpException('Invalid signature.');
    }
    return next(request);
  }
}
