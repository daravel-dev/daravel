// ADR-031: what the `process` cache store sends across isolates.
//
// The VM shares a string between the isolates of a process but copies a
// map or list, serialized by the sender, which for a cache read is the
// coordinator's single event loop. The store therefore sends maps, lists
// and strings as one JSON string, and numbers, booleans and null as they
// are (so `increment` works on a stored number). These tests pin the wire
// form, the round trip of every value kind, and that callers never share
// an object with the near cache.
import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Coordinator coordinator;
  late _WireChannel channel;

  setUp(() {
    coordinator = createStandardCoordinator();
    channel = _WireChannel(LocalCoordinatorChannel(coordinator));
  });
  tearDown(() => coordinator.close());

  test('maps, lists and strings cross as one JSON string', () async {
    final store = ProcessStore(channel);
    await store.put('map', {
      'theme': 'dark',
      'n': [1, 2],
    });
    await store.put('list', [1, 'two', null]);
    await store.put('text', 'hello');
    expect(channel.sent['map'], '{"theme":"dark","n":[1,2]}');
    expect(channel.sent['list'], '[1,"two",null]');
    expect(channel.sent['text'], '"hello"');
    expect(channel.sent.values, everyElement(isA<String>()));
  });

  test('numbers, booleans and null cross as they are', () async {
    final store = ProcessStore(channel);
    await store.put('int', 7);
    await store.put('double', 1.5);
    await store.put('bool', true);
    await store.putMany({'a': 1, 'b': 'x'});
    expect(channel.sent['int'], 7);
    expect(channel.sent['double'], 1.5);
    expect(channel.sent['bool'], true);
    expect(channel.sent['a'], 1);
    expect(channel.sent['b'], '"x"');
    // The coordinator holds the wire form, nothing decoded.
    final service =
        coordinator.service(ProcessCacheService.serviceName)!
            as ProcessCacheService;
    expect(await service.store.get('b'), '"x"');
    expect(await service.store.get('int'), 7);
  });

  test('every value kind round-trips through get, many and add', () async {
    final store = ProcessStore(channel);
    final values = <String, Object?>{
      'int': 7,
      'double': 1.5,
      'bool': false,
      'text': 'hello "quoted"',
      'map': {
        'nested': {'k': 'v'},
        'list': [1, 2.5, 'x', true, null],
      },
      'list': ['a', 1, null],
      'empty': '',
    };
    await store.putMany(values);
    for (final MapEntry(:key, :value) in values.entries) {
      expect(await store.get(key), value, reason: key);
    }
    expect(await store.many(['int', 'map', 'none']), {
      'int': 7,
      'map': values['map'],
      'none': null,
    });
    expect(await store.add('map', 'other'), isFalse);
    expect(await store.add('fresh', {'a': 1}), isTrue);
    expect(await store.get('fresh'), {'a': 1});
  });

  test('increment works on a stored number and a counter', () async {
    final store = ProcessStore(channel);
    await store.put('hits', 1);
    expect(await store.increment('hits'), 2);
    expect(await store.increment('new', 5), 5);
    expect(await store.get('hits'), 2);
  });

  test('a value JSON cannot encode still crosses, copied', () async {
    final store = ProcessStore(channel);
    final when = DateTime.utc(2026, 11, 5);
    await store.put('when', when);
    expect(channel.sent['when'], when);
    expect(await store.get('when'), when);
  });

  test('callers never share an object with the near cache', () async {
    final store = ProcessStore(channel, l1Ttl: const Duration(seconds: 5));
    await store.put('settings', {
      'theme': 'dark',
      'tags': ['a'],
    });
    final first = (await store.get('settings'))! as Map<Object?, Object?>;
    first['theme'] = 'changed';
    (first['tags']! as List<Object?>).add('b');
    final second = await store.get('settings');
    expect(second, {
      'theme': 'dark',
      'tags': ['a'],
    });
    expect(identical(first, second), isFalse);
    expect(channel.ops, ['put'], reason: 'both reads came from L1');
  });

  test('the wire codec is explicit', () {
    expect(ProcessStore.encodeWire(null), isNull);
    expect(ProcessStore.encodeWire(3), 3);
    expect(ProcessStore.encodeWire('s'), '"s"');
    expect(ProcessStore.encodeWire({'a': 1}), '{"a":1}');
    expect(ProcessStore.decodeWire('{"a":1}'), {'a': 1});
    expect(ProcessStore.decodeWire(3), 3);
    expect(ProcessStore.decodeWire(null), isNull);
  });
}

/// Records the wire value of every `put`, `putMany` and `add`.
final class _WireChannel implements CoordinatorChannel {
  _WireChannel(this.inner);

  final CoordinatorChannel inner;
  final Map<String, Object?> sent = <String, Object?>{};
  final List<String> ops = <String>[];

  @override
  StateScope get scope => inner.scope;

  @override
  bool get isRemote => inner.isRemote;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    ops.add(op);
    switch (op) {
      case 'put' || 'add':
        sent[args['key']! as String] = args['value'];
      case 'putMany':
        sent.addAll(args['values']! as Map<String, Object?>);
    }
    return inner.call(service, op, args, timeout: timeout);
  }
}
