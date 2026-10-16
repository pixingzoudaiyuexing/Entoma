import 'dart:async';
import 'dart:io';
import 'package:fl_clash/common/desktop_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy_platform_interface.dart';

class ProxyFixture {
  bool running = false, otherUsers = false, actual = false, owned = false;
  bool restoreOk = true, nativeOk = true, readbackOk = true;
  bool externallyUsesListener = false;
  int starts = 0, stops = 0, restores = 0, writes = 0;
  int concurrent = 0, maximumConcurrent = 0;
  Object? availabilityError;
  Completer<void>? listenerHold, applyHold;
  final listenerEntered = Completer<void>(), applyEntered = Completer<void>();
  final events = <String>[];
  late final coordinator = DesktopProxyCoordinator(
      configuration: () => DesktopProxyConfiguration(17890, ['localhost']),
      coreRunning: () => running,
      hasOtherCoreUsers: () => otherUsers,
      startCore: () async {
        starts++;
        running = true;
        events.add('core');
      },
      stopCore: () async {
        stops++;
        running = false;
        events.add('stop');
      },
      waitForListener: (_) async {
        events.add('listener');
        if (!listenerEntered.isCompleted) listenerEntered.complete();
        await listenerHold?.future;
      },
      apply: (_, __) async {
        writes++;
        owned = true;
        concurrent++;
        if (concurrent > maximumConcurrent) maximumConcurrent = concurrent;
        events.add('apply');
        if (!applyEntered.isCompleted) applyEntered.complete();
        await applyHold?.future;
        actual = true;
        concurrent--;
        return nativeOk;
      },
      restore: () async {
        restores++;
        concurrent++;
        if (concurrent > maximumConcurrent) maximumConcurrent = concurrent;
        events.add('restore');
        concurrent--;
        if (!restoreOk) return false;
        owned = false;
        actual = false;
        return true;
      },
      readback: (_, __) async {
        if (availabilityError != null) throw availabilityError!;
        events.add('readback');
        return ProxyStatus(
            available: true,
            matches: actual && readbackOk,
            owned: owned,
            restorationPending: false,
            usesListener: actual || externallyUsesListener);
      });
}

void main() {
  test('one intent starts core, waits for listener and actual native readback',
      () async {
    final f = ProxyFixture()..listenerHold = Completer<void>();
    final flight = f.coordinator.request(true);
    await f.listenerEntered.future;
    expect(f.coordinator.phase, DesktopProxyPhase.connecting);
    expect(f.writes, 0);
    f.listenerHold!.complete();
    await flight;
    expect(f.events, ['readback', 'core', 'listener', 'apply', 'readback']);
    expect(f.coordinator.phase, DesktopProxyPhase.connected);
    await f.coordinator.request(false);
    expect(f.events.sublist(5), ['restore', 'readback', 'stop']);
    expect(f.running, false);
  });

  test('rapid on/off/on converges with one native writer', () async {
    final f = ProxyFixture()..applyHold = Completer<void>();
    final on = f.coordinator.request(true);
    await f.applyEntered.future;
    final off = f.coordinator.request(false);
    final last = f.coordinator.request(true);
    f.applyHold!.complete();
    await Future.wait([on, off, last]);
    expect(f.maximumConcurrent, 1);
    expect(f.coordinator.phase, DesktopProxyPhase.connected);
    expect(f.starts, 1);
    await f.coordinator.request(false);
    expect(f.running, false);
  });

  test('off during pending apply waits then restores before stopping core',
      () async {
    final f = ProxyFixture()..applyHold = Completer<void>();
    final on = f.coordinator.request(true);
    await f.applyEntered.future;
    final off = f.coordinator.request(false);
    expect(f.restores, 0);
    expect(f.stops, 0);
    f.applyHold!.complete();
    await Future.wait([on, off]);
    expect(f.coordinator.phase, DesktopProxyPhase.disconnected);
    expect(f.maximumConcurrent, 1);
    expect(f.events.indexOf('restore'), greaterThan(f.events.indexOf('apply')));
    expect(f.events.indexOf('stop'), greaterThan(f.events.indexOf('restore')));
  });

  test('off before listener ready does not change system proxy', () async {
    final f = ProxyFixture()..listenerHold = Completer<void>();
    final on = f.coordinator.request(true);
    await f.listenerEntered.future;
    final off = f.coordinator.request(false);
    f.listenerHold!.complete();
    await Future.wait([on, off]);
    expect(f.writes, 0);
    expect(f.stops, 1);
    expect(f.coordinator.phase, DesktopProxyPhase.disconnected);
  });

  for (final failure in ['native', 'readback']) {
    test('$failure failure cannot report connected; partial write rolls back',
        () async {
      final f = ProxyFixture();
      f.nativeOk = failure != 'native';
      f.readbackOk = failure != 'readback';
      await f.coordinator.request(true);
      expect(f.coordinator.phase, DesktopProxyPhase.failed);
      expect(f.restores, 1);
      expect(f.actual, false);
      expect(f.running, false);
    });
  }

  test('failed restoration retains listener and retry owns the same snapshot',
      () async {
    final f = ProxyFixture();
    await f.coordinator.request(true);
    f.restoreOk = false;
    await f.coordinator.request(false);
    expect(f.coordinator.phase, DesktopProxyPhase.failed);
    expect(f.running, true);
    expect(f.owned, true);
    expect(f.stops, 0);
    f.restoreOk = true;
    await f.coordinator.request(false);
    expect(f.running, false);
    expect(f.owned, false);
    expect(f.stops, 1);
  });

  for (final alreadyRunning in [false, true]) {
    test('shared core retained (preexisting=$alreadyRunning)', () async {
      final f = ProxyFixture()..running = alreadyRunning;
      await f.coordinator.request(true);
      f.otherUsers = true;
      await f.coordinator.request(false);
      expect(f.running, true);
      expect(f.stops, 0);
      expect(f.starts, alreadyRunning ? 0 : 1);
    });
  }

  test('preexisting independent core is never stopped', () async {
    final f = ProxyFixture()..running = true;
    await f.coordinator.request(true);
    await f.coordinator.request(false);
    expect(f.running, true);
    expect(f.stops, 0);
  });

  test('external settings still using our listener prevent false stop success',
      () async {
    final f = ProxyFixture();
    await f.coordinator.request(true);
    f.externallyUsesListener = true;
    await f.coordinator.request(false);
    expect(f.coordinator.phase, DesktopProxyPhase.failed);
    expect(f.running, true);
    expect(f.stops, 0);
    f.externallyUsesListener = false;
    await f.coordinator.request(false);
    expect(f.coordinator.phase, DesktopProxyPhase.disconnected);
    expect(f.running, false);
  });

  test('unavailable backend fails before core startup without fake rollback',
      () async {
    final f = ProxyFixture()
      ..availabilityError = StateError('signing required');
    await f.coordinator.request(true);
    expect(f.coordinator.phase, DesktopProxyPhase.failed);
    expect(f.starts, 0);
    expect(f.writes, 0);
    expect(f.restores, 0);
  });

  test('crash or external change revokes connected and never auto-overwrites',
      () async {
    final f = ProxyFixture();
    await f.coordinator.request(true);
    f.actual = false;
    await f.coordinator.verify();
    expect(f.coordinator.phase, DesktopProxyPhase.failed);
    expect(f.writes, 1);
    expect(f.coordinator.desired, false);
    await f.coordinator.request(true);
    expect(f.coordinator.phase, DesktopProxyPhase.connected);
  });

  test('exit seals starts and awaits a delayed apply and full restoration',
      () async {
    final f = ProxyFixture()..applyHold = Completer<void>();
    final start = f.coordinator.request(true);
    await f.applyEntered.future;
    bool? exited;
    final exit = f.coordinator.prepareForExit().then((value) => exited = value);
    await expectLater(f.coordinator.request(true), throwsStateError);
    expect(exited, null);
    expect(f.restores, 0);
    f.applyHold!.complete();
    await Future.wait([start, exit]);
    expect(exited, true);
    expect(f.actual, false);
    // The final exit transaction owns core destruction after native restore.
    expect(f.stops, 0);
  });

  test('failed exit leaves a recoverable state and permits retry after cancel',
      () async {
    final f = ProxyFixture();
    await f.coordinator.request(true);
    f.restoreOk = false;
    expect(await f.coordinator.prepareForExit(), false);
    expect(f.running, true);
    f.coordinator.cancelExit();
    f.restoreOk = true;
    await f.coordinator.request(false);
    expect(f.coordinator.phase, DesktopProxyPhase.disconnected);
  });

  test('a later exit failure preserves auto core ownership across resume',
      () async {
    final f = ProxyFixture();
    await f.coordinator.request(true);
    expect(await f.coordinator.prepareForExit(), true);
    expect(f.running, true);
    // DNS/preferences may fail after system proxy restoration succeeded.
    f.coordinator.cancelExit();
    await f.coordinator.request(true);
    await f.coordinator.request(false);
    expect(f.stops, 1);
    expect(f.running, false);
  });

  test('startup can signal failed configuration intent without self-waiting',
      () async {
    final f = ProxyFixture()..listenerHold = Completer<void>();
    final on = f.coordinator.request(true);
    await f.listenerEntered.future;
    // Internal configuration errors signal cancellation and unwind; they do
    // not await the flight that is itself waiting for the startup callback.
    unawaited(f.coordinator.request(false));
    f.listenerHold!.complete();
    await on;
    expect(f.coordinator.phase, DesktopProxyPhase.disconnected);
    expect(f.writes, 0);
    expect(f.running, false);
  });

  test('mixed readiness verifies real SOCKS handshake with a local socket',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) {
      socket.listen((data) {
        if (data.length == 3 && data[0] == 5) socket.add([5, 0]);
      });
    });
    await waitForMixedProxy(server.port);
    await subscription.cancel();
    await server.close();
  });

  test('malformed native status is rejected instead of coerced to success', () {
    expect(
        () => ProxyStatus.fromMap({
              'available': true,
              'matches': 1,
              'owned': false,
              'restorationPending': false
            }),
        throwsStateError);
  });
}
