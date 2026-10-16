import 'dart:async';

import 'package:fl_clash/common/android_exit.dart';
import 'package:flutter_test/flutter_test.dart';

class _AndroidExitActions {
  final calls = <String>[];
  Future<void> Function()? preparation;
  Future<void> Function()? wait;
  Future<void> Function()? save;
  Future<bool> Function()? stop;
  Future<bool> Function()? shutdown;
  Future<bool> Function()? destroy;
  Future<void> Function()? finish;
  Future<void> Function()? cancel;

  late final coordinator = AndroidExitCoordinator(
    prepareForExit: () async {
      calls.add('prepare');
      await preparation?.call();
    },
    waitForOperations: () async {
      calls.add('wait');
      await wait?.call();
    },
    savePreferences: () async {
      calls.add('save');
      await save?.call();
    },
    stopVpn: () async {
      calls.add('stop-vpn');
      return await stop?.call() ?? true;
    },
    shutdownCore: () async {
      calls.add('shutdown-core');
      return await shutdown?.call() ?? true;
    },
    destroyEngine: () async {
      calls.add('destroy-engine');
      return await destroy?.call() ?? true;
    },
    exit: () async {
      calls.add('exit');
      await finish?.call();
    },
    cancelExit: () async {
      calls.add('cancel');
      await cancel?.call();
    },
  );
}

void main() {
  test('normal Android exit confirms VPN stop before core, engine and Activity',
      () async {
    final actions = _AndroidExitActions();
    expect(await actions.coordinator.requestExit(), isTrue);
    expect(
        actions.calls,
        containsAllInOrder(
            ['stop-vpn', 'shutdown-core', 'destroy-engine', 'exit']));
    expect(actions.calls, containsAll(['prepare', 'wait', 'save']));
    expect(actions.calls, isNot(contains('cancel')));
    expect(actions.coordinator.isClosing, isTrue);
  });

  testWidgets('VPN stop slower than 300 ms cannot destroy engine or exit',
      (tester) async {
    final actions = _AndroidExitActions();
    final stop = Completer<bool>();
    actions.stop = () => stop.future;
    final result = actions.coordinator.requestExit();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(actions.calls, contains('stop-vpn'));
    expect(actions.calls, isNot(contains('shutdown-core')));
    expect(actions.calls, isNot(contains('destroy-engine')));
    expect(actions.calls, isNot(contains('exit')));
    stop.complete(true);
    await tester.pump();
    expect(await result, isTrue);
    expect(
        actions.calls,
        containsAllInOrder(
            ['stop-vpn', 'shutdown-core', 'destroy-engine', 'exit']));
  });

  testWidgets('admitted operation drains before VPN cleanup', (tester) async {
    final actions = _AndroidExitActions();
    final drain = Completer<void>();
    actions.wait = () => drain.future;
    final result = actions.coordinator.requestExit();
    await tester.pump(const Duration(seconds: 1));
    expect(actions.calls, contains('wait'));
    expect(actions.calls, isNot(contains('stop-vpn')));
    drain.complete();
    await tester.pump();
    expect(await result, isTrue);
  });

  test('concurrent and completed exits share one shutdown transaction',
      () async {
    final actions = _AndroidExitActions();
    final pending = Completer<void>();
    actions.preparation = () => pending.future;
    final first = actions.coordinator.requestExit();
    final second = actions.coordinator.requestExit();
    expect(identical(first, second), isTrue);
    expect(actions.coordinator.isClosing, isTrue);
    pending.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(await actions.coordinator.requestExit(), isTrue);
    for (final name in [
      'prepare',
      'save',
      'stop-vpn',
      'shutdown-core',
      'destroy-engine',
      'exit'
    ]) {
      expect(actions.calls.where((call) => call == name), hasLength(1),
          reason: name);
    }
  });

  test('failed admitted operation still performs separately owned VPN cleanup',
      () async {
    final actions = _AndroidExitActions();
    actions.wait =
        () async => throw StateError('profile transaction rolled back');
    expect(await actions.coordinator.requestExit(), isTrue);
    expect(
        actions.calls,
        containsAllInOrder(
            ['wait', 'stop-vpn', 'shutdown-core', 'destroy-engine', 'exit']));
  });

  for (final phase in [
    'prepare',
    'save',
    'stop-vpn',
    'shutdown-core',
    'destroy-engine'
  ]) {
    test('$phase exception keeps Activity alive and permits explicit retry',
        () async {
      final actions = _AndroidExitActions();
      Future<void> failure() async =>
          throw StateError('injected $phase failure');
      Future<bool> boolFailure() async =>
          throw StateError('injected $phase failure');
      switch (phase) {
        case 'prepare':
          actions.preparation = failure;
        case 'save':
          actions.save = failure;
        case 'stop-vpn':
          actions.stop = boolFailure;
        case 'shutdown-core':
          actions.shutdown = boolFailure;
        case 'destroy-engine':
          actions.destroy = boolFailure;
      }
      expect(await actions.coordinator.requestExit(), isFalse);
      final teardownStarted =
          phase == 'shutdown-core' || phase == 'destroy-engine';
      expect(actions.calls,
          teardownStarted ? isNot(contains('cancel')) : contains('cancel'));
      expect(actions.coordinator.isClosing, teardownStarted);
      expect(actions.calls, isNot(contains('exit')));
      if (phase == 'prepare' || phase == 'save' || phase == 'stop-vpn') {
        expect(actions.calls, isNot(contains('shutdown-core')));
        expect(actions.calls, isNot(contains('destroy-engine')));
      }
      actions.preparation = null;
      actions.wait = null;
      actions.save = null;
      actions.stop = null;
      actions.shutdown = null;
      actions.destroy = null;
      actions.finish = null;
      expect(await actions.coordinator.requestExit(), isTrue);
    });
  }

  test('Activity finishing failure retries only pop after engine was destroyed',
      () async {
    final actions = _AndroidExitActions();
    actions.finish = () async => throw StateError('activity finishing failed');
    expect(await actions.coordinator.requestExit(), isFalse);
    expect(actions.coordinator.isClosing, isTrue);
    expect(actions.calls, isNot(contains('cancel')));
    actions.finish = null;
    expect(await actions.coordinator.requestExit(), isTrue);
    expect(actions.calls.where((call) => call == 'stop-vpn'), hasLength(1));
    expect(
        actions.calls.where((call) => call == 'shutdown-core'), hasLength(1));
    expect(
        actions.calls.where((call) => call == 'destroy-engine'), hasLength(1));
    expect(actions.calls.where((call) => call == 'exit'), hasLength(2));
  });

  for (final phase in ['stop-vpn', 'shutdown-core', 'destroy-engine']) {
    test('$phase false acknowledgement cannot be reported as successful exit',
        () async {
      final actions = _AndroidExitActions();
      if (phase == 'stop-vpn') actions.stop = () async => false;
      if (phase == 'shutdown-core') actions.shutdown = () async => false;
      if (phase == 'destroy-engine') actions.destroy = () async => false;
      expect(await actions.coordinator.requestExit(), isFalse);
      expect(actions.calls, isNot(contains('exit')));
      final teardownStarted = phase != 'stop-vpn';
      expect(actions.calls,
          teardownStarted ? isNot(contains('cancel')) : contains('cancel'));
      expect(actions.coordinator.isClosing, teardownStarted);
      if (phase == 'stop-vpn') {
        expect(actions.calls, isNot(contains('shutdown-core')));
        expect(actions.calls, isNot(contains('destroy-engine')));
      }
      if (phase == 'shutdown-core') {
        expect(actions.calls, isNot(contains('destroy-engine')));
      }
      actions.stop = null;
      actions.shutdown = null;
      actions.destroy = null;
      expect(await actions.coordinator.requestExit(), isTrue);
    });
  }

  test('synchronous preparation throw does not permanently retain the flight',
      () async {
    var attempts = 0;
    final coordinator = AndroidExitCoordinator(
      prepareForExit: () {
        attempts++;
        throw StateError('synchronous preparation failure');
      },
      waitForOperations: () async {},
      savePreferences: () async {},
      stopVpn: () async => true,
      shutdownCore: () async => true,
      destroyEngine: () async => true,
      exit: () async {},
      cancelExit: () async {},
    );
    expect(await coordinator.requestExit(), isFalse);
    expect(await coordinator.requestExit(), isFalse);
    expect(attempts, 2);
  });

  test('failed cancellation retains start gate but can be retried explicitly',
      () async {
    final actions = _AndroidExitActions();
    actions.stop = () async => false;
    actions.cancel = () async => throw StateError('native cancellation failed');
    expect(await actions.coordinator.requestExit(), isFalse);
    expect(actions.coordinator.isClosing, isTrue);
    expect(actions.calls, isNot(contains('exit')));
    actions.stop = null;
    actions.cancel = null;
    expect(await actions.coordinator.requestExit(), isTrue);
  });
}
