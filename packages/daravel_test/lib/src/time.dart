import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Freezes [Clock] at the current instant until the test ends
/// (`$this->freezeTime()`).
DateTime freezeTime() {
  addTearDown(Clock.restore);
  return Clock.freeze();
}

/// Moves frozen time by [duration] (`$this->travel(5)->minutes()`).
DateTime travel(Duration duration) {
  addTearDown(Clock.restore);
  return Clock.travel(duration);
}

/// Freezes time at [time] (`$this->travelTo($date)`).
DateTime travelTo(DateTime time) {
  addTearDown(Clock.restore);
  return Clock.travelTo(time);
}

/// Back to real time (`$this->travelBack()`).
void travelBack() => Clock.restore();
