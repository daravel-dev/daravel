import 'package:daravel/daravel.dart';

/// One of the processes of `file_store_processes_test.dart`: increments the
/// shared counter, rewrites a shared key and forgets it, [rounds] times, in
/// the cache directory given as first argument.
Future<void> main(List<String> args) async {
  final store = FileStore(args[0]);
  final rounds = int.parse(args[1]);
  final worker = args[2];
  for (var i = 0; i < rounds; i++) {
    await Future.wait(<Future<Object?>>[
      store.increment('counter'),
      store.put('shared', '$worker:$i'),
      store.forget('shared'),
      store.add('added', worker),
    ]);
  }
}
