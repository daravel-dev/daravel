/// `Process.run`, `pipe`, `pool` and `fake`, as Laravel's `Process` facade.
///
/// Not part of `package:daravel/daravel.dart`: its `Process` would collide
/// with `dart:io`'s in every file that imports both. Import this library
/// where you run commands, with a prefix if the file also needs `dart:io`'s.
library;

export 'src/process/process.dart';
