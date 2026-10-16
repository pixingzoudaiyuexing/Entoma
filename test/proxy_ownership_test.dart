import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/manager/proxy_manager.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:fl_clash/models/models.dart' hide Proxy;
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/desktop_proxy.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:proxy/proxy.dart';
import 'package:proxy/proxy_platform_interface.dart';

class FakeNativeProxy extends ProxyPlatform {
  Object? startError;
  bool? startResult = true;
  bool? stopResult = true;
  Completer<bool?>? startBlock;
  final entered = Completer<void>();
  int stops = 0;
  @override
  Future<bool?> startProxy(int port, List<String> bypassDomain) async {
    if (!entered.isCompleted) entered.complete();
    if (startError != null) throw startError!;
    return startBlock != null ? await startBlock!.future : startResult;
  }

  @override
  Future<bool?> stopProxy() async {
    stops++;
    return stopResult;
  }
}

class _ClosingController extends AppController {
  _ClosingController(super.context, super.ref);
  @override
  bool get isClosing => true;
}

class _ProxyController extends AppController {
  final FakeNativeProxy native;
  bool running = true;
  _ProxyController(super.context, super.ref, this.native);
  @override
  late final desktopProxy = DesktopProxyCoordinator(
      configuration: () => DesktopProxyConfiguration(7890, []),
      coreRunning: () => running,
      hasOtherCoreUsers: () => true,
      startCore: () async {
        running = true;
      },
      stopCore: () async {
        running = false;
      },
      waitForListener: (_) async {},
      apply: native.startProxy,
      restore: native.stopProxy,
      readback: (_, __) async => const ProxyStatus(
          available: true,
          matches: true,
          owned: false,
          restorationPending: false));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProxyPlatform previous;
  setUp(() => previous = ProxyPlatform.instance);
  tearDown(() => ProxyPlatform.instance = previous);
  for (final platform in ['macos', 'windows']) {
    for (final outcome in ['success', 'false', 'null', 'throw']) {
      test('$platform native $outcome start preserves restoration retries',
          () async {
        final native = FakeNativeProxy();
        ProxyPlatform.instance = native;
        final proxy = Proxy.forPlatform(platform);
        if (outcome == 'throw') native.startError = StateError('partial start');
        if (outcome == 'false') native.startResult = false;
        if (outcome == 'null') native.startResult = null;
        if (outcome == 'throw') {
          await expectLater(proxy.startProxy(7890), throwsStateError);
        } else {
          expect(await proxy.startProxy(7890), native.startResult);
        }
        native.stopResult = false;
        expect(await proxy.stopProxy(), false);
        native.stopResult = true;
        expect(await proxy.stopProxy(), true);
        expect(native.stops, 2);
        // A repeated native stop is safe because native snapshot ownership is
        // authoritative. Dart never reports ownership after failed starts.
        expect(await proxy.stopProxy(), true);
        expect(native.stops, 3);
      });
    }
  }
  testWidgets(
      'desktop teardown does not race awaited exit restoration with late apply',
      (tester) async {
    globalState.config = Config(themeProps: defaultThemeProps);
    globalState.appState = AppState(
        viewSize: Size.zero,
        version: 29,
        requests: FixedList<Connection>(10),
        logs: FixedList<Log>(10),
        traffics: FixedList<Traffic>(10),
        totalTraffic: Traffic(),
        isInit: true);
    final native = FakeNativeProxy()..startBlock = Completer<bool?>();
    ProxyPlatform.instance = native;
    late _ProxyController controller;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          proxyStateProvider.overrideWithValue(const ProxyState(
              isStart: true, systemProxy: true, bassDomain: [], port: 7890))
        ],
        child: Consumer(builder: (context, ref, child) {
          controller = _ProxyController(context, ref, native);
          globalState.appController = controller;
          return const MaterialApp(home: ProxyManager(child: SizedBox()));
        })));
    await tester.pump();
    final connecting = controller.setSystemProxyEnabled(true);
    await tester.pump();
    await native.entered.future;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(native.stops, 0);
    final exiting = controller.desktopProxy.prepareForExit();
    native.startBlock!.complete(true);
    await tester.pumpAndSettle();
    await connecting;
    expect(await exiting, true);
    expect(native.stops, 1);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isMacOS && !Platform.isWindows);

  testWidgets('macOS closing suppresses new manager and controller starts',
      (tester) async {
    final native = FakeNativeProxy();
    ProxyPlatform.instance = native;
    final wasInitialized = globalState.isInit;
    late _ClosingController controller;
    try {
      await tester.pumpWidget(ProviderScope(
          overrides: [
            proxyStateProvider.overrideWithValue(const ProxyState(
                isStart: true, systemProxy: true, bassDomain: [], port: 7890))
          ],
          child: Consumer(builder: (context, ref, child) {
            controller = _ClosingController(context, ref);
            globalState.appController = controller;
            return const MaterialApp(home: ProxyManager(child: SizedBox()));
          })));
      await tester.pumpAndSettle();
      expect(native.entered.isCompleted, isFalse);
      expect(native.stops, 0,
          reason:
              'the awaited exit transaction owns restoration, not a second widget queue');
      // Exercise the real controller entry points. The closing check must run
      // before native core/session/profile work, even if a callback fires late.
      await controller.updateStatus(true);
      await controller.restartCore();
      await expectLater(
          controller.applyProfile(silence: true), throwsStateError);
      controller.handleChangeProfile();
      controller.applyProfileDebounce(silence: true);
      await tester.pump(const Duration(seconds: 1));
      expect(native.entered.isCompleted, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      globalState.isInit = wasInitialized;
    }
  }, skip: !Platform.isMacOS);
}
