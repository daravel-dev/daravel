import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Services allowed to answer with a `Future`, and why. Everything else the
/// standard coordinator hosts must answer synchronously: the coordinator
/// runs on the supervisor's main isolate, where a slow asynchronous service
/// would also delay worker respawns and drains.
const Map<String, String> _asyncAllowed = {
  // Wraps MemoryStore, whose CacheStore interface is asynchronous; the work
  // is in memory and completes in microtasks, without I/O. Its locks use
  // the synchronous *Sync methods.
  'ProcessCacheService': 'MemoryStore behind the async CacheStore API',
};

void main() {
  test('every standard coordinator service answers synchronously', () {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final classes = {
      for (final name in coordinator.serviceNames)
        coordinator.service(name)!.runtimeType.toString(),
    };
    expect(classes, isNotEmpty);
    expect(
      _asyncAllowed.keys,
      everyElement(isIn(classes)),
      reason: 'an allowed service that is no longer registered',
    );

    final handles = _handleMethods(p.join(Directory.current.path, 'lib'));
    for (final service in classes) {
      final method = handles['$service.handle'];
      expect(method, isNotNull, reason: '$service.handle not found in lib/');
      if (!_asyncAllowed.containsKey(service)) {
        expect(
          _isAsync(method!),
          isFalse,
          reason:
              '$service.handle returns a Future: the coordinator answers on '
              'the supervisor isolate; make it synchronous or add it to '
              '_asyncAllowed with the reason',
        );
      }
      // The typed path (ADR-031) carries the hottest calls (rate limits,
      // locks): synchronous for every service, without exception.
      final typed = handles['$service.handleTyped'];
      if (coordinator.service(_nameOf(coordinator, service))
          is TypedCoordinatorService<Object>) {
        expect(
          typed,
          isNotNull,
          reason: '$service.handleTyped not found in lib/',
        );
        expect(
          _isAsync(typed!),
          isFalse,
          reason: '$service.handleTyped returns a Future',
        );
      }
    }
  });
}

/// The registered name of the service whose class is [className].
String _nameOf(Coordinator coordinator, String className) =>
    coordinator.serviceNames.firstWhere(
      (name) => coordinator.service(name)!.runtimeType.toString() == className,
    );

bool _isAsync(MethodDeclaration method) =>
    method.body.isAsynchronous ||
    RegExp(r'^(Future|FutureOr)\b')
        .hasMatch(method.returnType?.toSource() ?? '');

final RegExp _implementsService = RegExp(
  r'implements\s+(Typed)?CoordinatorService\b',
);

/// `handle` and `handleTyped` of every class in [lib] that implements
/// `CoordinatorService` or `TypedCoordinatorService`, as
/// `Class.method`.
Map<String, MethodDeclaration> _handleMethods(String lib) {
  final found = <String, MethodDeclaration>{};
  for (final file in Directory(lib).listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) {
      continue;
    }
    final source = file.readAsStringSync();
    if (!_implementsService.hasMatch(source)) {
      continue;
    }
    parseString(
      content: source,
      path: file.path,
    ).unit.accept(_HandleVisitor(found));
  }
  return found;
}

final class _HandleVisitor extends RecursiveAstVisitor<void> {
  _HandleVisitor(this.found);

  final Map<String, MethodDeclaration> found;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final owner = node.thisOrAncestorOfType<ClassDeclaration>();
    final method = node.name.lexeme;
    if ((method == 'handle' || method == 'handleTyped') && owner != null) {
      final header = owner.toSource();
      final name = RegExp(r'class\s+(\w+)').firstMatch(header)?.group(1);
      if (name != null && _implementsService.hasMatch(header)) {
        found['$name.$method'] = node;
      }
    }
    super.visitMethodDeclaration(node);
  }
}
