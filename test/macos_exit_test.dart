import 'dart:async';

import 'package:fl_clash/common/macos_exit.dart';
import 'package:flutter_test/flutter_test.dart';

class _ExitActions {
  final List<String> calls = [];
  Future<void> Function()? preparation;
  Future<void> Function()? configuration;
  Future<bool> Function()? dns;
  Future<bool> Function()? proxy;
  Future<void> Function()? shutdown;
  Future<void> Function()? save;

  late final coordinator = MacOSExitCoordinator(
    prepareForExit: () async {
      calls.add('prepare');
      await preparation?.call();
    },
    waitForConfiguration: () async {
      calls.add('configuration');
      await configuration?.call();
    },
    restoreDns: () async {
      calls.add('dns');
      return await dns?.call() ?? true;
    },
    restoreProxy: () async {
      calls.add('proxy');
      return await proxy?.call() ?? true;
    },
    shutdown: () async {
      calls.add('shutdown');
      await shutdown?.call();
    },
    savePreferences: () async {
      calls.add('save');
      await save?.call();
    },
    exit: () async {
      calls.add('exit');
    },
  );
}

const _success = [
  'prepare',
  'configuration',
  'dns',
  'proxy',
  'shutdown',
  'save',
  'exit'
];

void main() {
  test('synchronous preparation failure releases the flight for retry',
      () async {
    var attempts = 0;
    final coordinator = MacOSExitCoordinator(
      prepareForExit: () {
        attempts++;
        throw StateError('synchronous failure');
      },
      waitForConfiguration: () async {},
      restoreDns: () async => true,
      restoreProxy: () async => true,
      shutdown: () async {},
      savePreferences: () async {},
      exit: () async {},
    );
    expect(await coordinator.requestExit(), isFalse);
    expect(await coordinator.requestExit(), isFalse);
    expect(attempts, 2);
  });
  testWidgets(
      'exit waits past the old 300ms limit for configuration and restore',
      (tester) async {
    final actions = _ExitActions();
    final configuration = Completer<void>();
    final restore = Completer<bool>();
    actions.configuration = () => configuration.future;
    actions.dns = () => restore.future;
    final result = actions.coordinator.requestExit();
    expect(actions.coordinator.isClosing, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(actions.calls, ['prepare', 'configuration']);
    configuration.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(actions.calls, ['prepare', 'configuration', 'dns']);
    restore.complete(true);
    await tester.pump();
    expect(await result, isTrue);
    expect(actions.calls, _success);
  });

  test('concurrent exits share one flight, completed exit cannot run twice',
      () async {
    final actions = _ExitActions();
    final pending = Completer<void>();
    actions.preparation = () => pending.future;
    final first = actions.coordinator.requestExit();
    final second = actions.coordinator.requestExit();
    expect(identical(first, second), isTrue);
    expect(actions.calls, ['prepare']);
    pending.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(await actions.coordinator.requestExit(), isTrue);
    expect(actions.calls, _success);
    expect(actions.coordinator.isClosing, isTrue);
  });

  for (final action in ['dns', 'proxy']) {
    for (final throwsError in [false, true]) {
      test(
          '$action ${throwsError ? "error" : "false"} still tries both restores, keeps app alive, allows retry',
          () async {
        final actions = _ExitActions();
        Future<bool> fail() async {
          if (throwsError) throw StateError('injected restore failure');
          return false;
        }

        if (action == 'dns') {
          actions.dns = fail;
        } else {
          actions.proxy = fail;
        }
        expect(await actions.coordinator.requestExit(), isFalse);
        expect(actions.calls, ['prepare', 'configuration', 'dns', 'proxy']);
        expect(actions.coordinator.isClosing, isFalse);
        actions.dns = null;
        actions.proxy = null;
        expect(await actions.coordinator.requestExit(), isTrue);
        expect(actions.calls.skip(4).toList(), _success);
      });
    }
  }

  test('cancel pending launch completes before draining core operations',
      () async {
    final actions = _ExitActions();
    final pendingCore = Completer<void>();
    actions.preparation = () async {
      pendingCore.complete();
    };
    actions.configuration = () => pendingCore.future;
    expect(await actions.coordinator.requestExit(), isTrue);
    expect(actions.calls, _success);
  });

  test('failed configuration does not prevent owned restore', () async {
    final actions = _ExitActions();
    actions.configuration = () async {
      throw StateError('injected stale config');
    };
    expect(await actions.coordinator.requestExit(), isTrue);
    expect(actions.calls, _success);
  });

  for (final action in ['prepare', 'shutdown', 'save']) {
    test('$action failure never exits and is retryable', () async {
      final actions = _ExitActions();
      Future<void> fail() async {
        throw StateError('injected failure');
      }

      switch (action) {
        case 'prepare':
          actions.preparation = fail;
        case 'shutdown':
          actions.shutdown = fail;
        case 'save':
          actions.save = fail;
      }
      expect(await actions.coordinator.requestExit(), isFalse);
      expect(actions.calls, isNot(contains('exit')));
      expect(actions.coordinator.isClosing, isFalse);
      actions.preparation = null;
      actions.shutdown = null;
      actions.save = null;
      actions.calls.clear();
      expect(await actions.coordinator.requestExit(), isTrue);
      expect(actions.calls, _success);
    });
  }
}
