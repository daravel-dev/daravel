import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

class Counter {
  Counter() {
    instances++;
  }

  static int instances = 0;
  int value = 0;
}

class A {
  A(this.b);
  final B b;
}

class B {
  B(this.a);
  final A a;
}

void main() {
  setUp(() {
    Counter.instances = 0;
    Container.setRoot(null);
  });

  group('lifetimes', () {
    test('singleton is created once and cached', () {
      final c = Container()..singleton<Counter>((_) => Counter());
      expect(identical(c.make<Counter>(), c.make<Counter>()), isTrue);
      expect(Counter.instances, 1);
      expect(c.resolved<Counter>(), isNotNull);
    });

    test('transient creates a new instance each time', () {
      final c = Container()..bind<Counter>((_) => Counter());
      expect(identical(c.make<Counter>(), c.make<Counter>()), isFalse);
      expect(Counter.instances, 2);
    });

    test('instance returns the registered object', () {
      final counter = Counter();
      final c = Container()..instance<Counter>(counter);
      expect(identical(c.make<Counter>(), counter), isTrue);
      expect(c.bound<Counter>(), isTrue);
    });

    test('named bindings are independent from the default binding', () {
      final c = Container()
        ..singleton<Counter>((_) => Counter(), name: 'a')
        ..singleton<Counter>((_) => Counter(), name: 'b');
      expect(
        identical(c.make<Counter>(name: 'a'), c.make<Counter>(name: 'b')),
        isFalse,
      );
      expect(
        () => c.make<Counter>(),
        throwsA(isA<BindingResolutionException>()),
      );
      expect(c.tryMake<Counter>(), isNull);
    });

    test('scoped bindings cannot be resolved outside a scope', () {
      final c = Container()..scoped<Counter>((_) => Counter());
      expect(() => c.make<Counter>(), throwsA(isA<ScopeRequiredException>()));
    });

    test('circular dependencies are detected', () {
      final c = Container()
        ..singleton<A>((c) => A(c.make<B>()))
        ..singleton<B>((c) => B(c.make<A>()));
      expect(() => c.make<A>(), throwsA(isA<CircularDependencyException>()));
    });

    test('forget removes bindings and instances', () {
      final c = Container()..singleton<Counter>((_) => Counter());
      c.make<Counter>();
      c.forget<Counter>();
      expect(c.bound<Counter>(), isFalse);
    });
  });

  group('scopes', () {
    test('scoped instances are shared inside a scope and isolated across '
        '200 concurrent scopes', () async {
      final c = Container()..scoped<Counter>((_) => Counter());
      final results = await Future.wait(
        List<Future<bool>>.generate(
          200,
          (i) => c.runScoped<bool>('request', (scope) async {
            final first = c.make<Counter>()..value = i;
            await Future<void>.delayed(Duration(milliseconds: i % 7));
            final second = c.make<Counter>();
            return identical(first, second) &&
                second.value == i &&
                identical(scope.get<Counter>(), first);
          }),
        ),
      );
      expect(results.every((ok) => ok), isTrue);
      expect(Counter.instances, 200);
    });

    test('dispose callbacks run LIFO after the body completes', () async {
      final c = Container();
      final order = <String>[];
      Scope? captured;
      await c.runScoped<void>('test', (scope) async {
        captured = scope;
        scope.onDispose(() => order.add('first'));
        scope.onDispose(() async {
          await Future<void>.delayed(Duration.zero);
          order.add('second');
        });
      });
      expect(order, <String>['second', 'first']);
      expect(captured!.disposed, isTrue);
    });

    test('errors thrown by the body propagate to the caller', () async {
      final c = Container();
      await expectLater(
        c.runScoped<void>('test', (_) async => throw StateError('boom')),
        throwsStateError,
      );
    });

    test('an uncaught async error before completion fails the scope', () async {
      final c = Container();
      await expectLater(
        c.runScoped<int>('test', (_) async {
          unawaited(
            Future<void>.delayed(Duration.zero, () => throw StateError('late')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 42;
        }),
        throwsStateError,
      );
    });

    test(
      'an uncaught async error after completion is reported, not fatal',
      () async {
        final c = Container();
        Object? reported;
        final result = await c.runScoped<int>('test', (_) async {
          unawaited(
            Future<void>.delayed(
              const Duration(milliseconds: 10),
              () => throw StateError('after'),
            ),
          );
          return 7;
        }, onUncaughtError: (error, _) => reported = error);
        expect(result, 7);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(reported, isA<StateError>());
      },
    );

    test(
      'Container.current prefers the zone container, then the root',
      () async {
        expect(() => Container.current, throwsStateError);
        final root = Container();
        Container.setRoot(root);
        expect(identical(Container.current, root), isTrue);

        final other = Container();
        await other.runScoped<void>('x', (_) async {
          expect(identical(Container.current, other), isTrue);
          await Future<void>.delayed(Duration.zero);
          expect(identical(Container.current, other), isTrue);
        });
        expect(identical(Container.current, root), isTrue);
      },
    );
  });
}
