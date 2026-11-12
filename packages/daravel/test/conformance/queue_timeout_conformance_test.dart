@Tags(['conformance'])
library;

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:test/test.dart';

/// A job failed for running past its timeout carries Laravel's error text,
/// so a `failed_jobs` table shared with Laravel reads the same, whichever
/// worker (the job's own timer, or Horizon's master after a kill) saw it.
void main() {
  test('TimeoutExceededException: "<name> has timed out."', () {
    expect(
      TimeoutExceededException('App\\Jobs\\SendInvoice').message,
      LaravelContract.jobTimedOut('App\\Jobs\\SendInvoice'),
    );
  });
}
