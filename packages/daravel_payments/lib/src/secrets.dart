/// [value], refused with an [ArgumentError] when it is empty or only
/// whitespace: a gateway would otherwise sign or check webhooks with an
/// empty key, which anyone can compute. stripe-php refuses such a webhook
/// secret too (`WebhookSignature::verifyHeader`, v23.0.0).
String requireSecret(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(
      value.isEmpty ? value : '(blank)',
      name,
      'must not be empty or blank',
    );
  }
  return value;
}
