import '../../routing/url_signer.dart';
import '../http_exceptions.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Rejects requests whose URL signature is missing, invalid or expired
/// (`signed` middleware alias; Laravel `ValidateSignature`).
final class ValidateSignatureMiddleware implements Middleware {
  const ValidateSignatureMiddleware(this.signer);

  final UrlSigner signer;

  @override
  Future<Response> handle(Request request, Next next) {
    if (!signer.verify(request.uri, host: request.signedHost)) {
      throw const ForbiddenHttpException('Invalid signature.');
    }
    return next(request);
  }
}
