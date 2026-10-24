import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('request ids are 24 lowercase hex characters and unique', () {
    final ids = {for (var i = 0; i < 1000; i++) RequestId.generate()};
    expect(ids, hasLength(1000));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[0-9a-f]{24}$')));
    }
  });
}
