import 'dart:async';
import 'dart:io';

import 'package:fl_clash/clash/clash.dart';
import 'package:fl_clash/clash/interface.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/desktop_proxy.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/proxy_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:fl_clash/views/dashboard/widgets/quick_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:proxy/proxy_platform_interface.dart';

import 'legacy_entry_regression_test.dart' show FixturePaths;

class _RollbackCore implements ClashHandlerInterface {
  int setups = 0;
  int configs = 0;

  @override
  Future<bool> forceGc() async => true;

  @override
  Future<Result> getConfig(String path) async {
    configs++;
    return Result.success(<String, dynamic>{});
  }

  @override
  Future<String> setupConfig(SetupParams params) async {
    setups++;
    return 'fixture setup failed; rollback failed';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends AppController {
  _Controller(BuildContext context, this.fixtureRef)
      : super(context, fixtureRef);
  final WidgetRef fixtureRef;
  late DesktopProxyCoordinator fixture;
  int manualStartCalls = 0;

  @override
  bool get usesDesktopProxy => true;

  @override
  DesktopProxyCoordinator get desktopProxy => fixture;

  @override
  Future<void> updateStatus(bool running) async {
    manualStartCalls++;
    throw StateError('The system-proxy switch must not need the play button');
  }
}

class _ProxyActions {
  bool running = false;
  bool applied = false;
  int starts = 0;
  int writes = 0;
  int restores = 0;
  Object? writeFailure;
  Future<void> Function()? starting;
  final events = <String>[];
  final phases = <DesktopProxyPhase>[];

  late final DesktopProxyCoordinator coordinator = DesktopProxyCoordinator(
    configuration: () => DesktopProxyConfiguration(17890, ['localhost']),
    coreRunning: () => running,
    hasOtherCoreUsers: () => false,
    startCore: () async {
      starts++;
      events.add('start');
      // Represents resources acquired by startup before configuration fails.
      running = true;
      await starting?.call();
    },
    stopCore: () async {
      events.add('stop');
      running = false;
    },
    waitForListener: (_) async => events.add('listener'),
    apply: (_, __) async {
      writes++;
      events.add('apply');
      if (writeFailure != null) throw writeFailure!;
      applied = true;
      return true;
    },
    restore: () async {
      restores++;
      events.add('restore');
      applied = false;
      return true;
    },
    readback: (_, __) async => ProxyStatus(
      available: true,
      matches: applied,
      owned: applied,
      restorationPending: false,
    ),
  )..addListener(() => phases.add(coordinator.phase));
}

class _InitializationController extends AppController {
  _InitializationController(super.context, super.ref, this.actions);
  final _ProxyActions actions;
  Future<void> Function()? preparing;
  @override
  bool get usesDesktopProxy => true;
  @override
  DesktopProxyCoordinator get desktopProxy => actions.coordinator;
  @override
  Future<void> prepareCore() async => await preparing?.call();
  @override
  Future<void> restartCore() async {}
  @override
  Future<void> applyProfile({bool silence = false}) async {}
  @override
  Future<void> autoCheckUpdate() async {}
  @override
  Future<void> autoUpdateProfiles() async {}
  @override
  Future<void> updateTray([bool focus = false]) async {}
}

class _ListenerCore implements ClashHandlerInterface {
  _ListenerCore(this.actions);
  final _ProxyActions actions;
  int starts = 0;
  final trafficRead = Completer<void>();
  @override
  Future<bool> startListener() async {
    starts++;
    actions.running = true;
    return true;
  }

  @override
  Future<bool> stopListener() async {
    actions.running = false;
    return true;
  }

  @override
  Future<void> resetTraffic() async {}
  @override
  Future<String> getTraffic() async => '{"up":0,"down":0}';
  @override
  Future<String> getTotalTraffic() async {
    if (!trafficRead.isCompleted) trafficRead.complete();
    return '{"up":0,"down":0}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_Controller> _mount(WidgetTester tester, _ProxyActions actions,
    {Widget body = const SizedBox.shrink(), bool withManager = false}) async {
  late _Controller controller;
  var created = false;
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: Consumer(builder: (context, ref, _) {
      ref.watch(profilesProvider);
      ref.watch(currentProfileIdProvider);
      ref.watch(networkSettingProvider);
      ref.watch(patchClashConfigProvider);
      ref.watch(appSettingProvider);
      if (!created) {
        controller = _Controller(context, ref)..fixture = actions.coordinator;
        globalState.appController = controller;
        globalState.theme = CommonTheme.of(context, 1);
        globalState.measure = Measure.of(context, 1);
        created = true;
      }
      return Scaffold(body: withManager ? ProxyManager(child: body) : body);
    })),
  ));
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AppLocalizations.load(const Locale('en'));
    globalState.config = Config(
      themeProps: defaultThemeProps,
      networkProps: const NetworkProps(systemProxy: false),
      patchClashConfig: const ClashConfig(tun: Tun(enable: false)),
    );
    globalState.appState = AppState(
      viewSize: const Size(800, 600),
      version: 29,
      requests: FixedList<Connection>(10),
      logs: FixedList<Log>(10),
      traffics: FixedList<Traffic>(10),
      totalTraffic: Traffic(),
    );
    globalState.packageInfo = PackageInfo(
      appName: 'Entoma',
      packageName: 'com.entoma.client',
      version: '0.1.0',
      buildNumber: '1',
    );
    globalState.startTime = null;
  });

  tearDown(() {
    debouncer.cancel(FunctionTag.addCheckIpNum);
    globalState.stopUpdateTasks();
  });

  for (final autoRun in [false, true]) {
    for (final mode in [false, true]) {
      for (final earlyIntent
          in autoRun == mode ? <bool?>[null, !autoRun] : <bool?>[null]) {
        final connects = earlyIntent ?? (autoRun && mode);
        testWidgets(
            'full initialization autoRun=$autoRun proxyMode=$mode early=$earlyIntent',
            (tester) async {
          SharedPreferences.setMockInitialValues({});
          final binding = TestDefaultBinaryMessengerBinding.instance;
          const windowChannel = MethodChannel('window_manager');
          late Completer<void> windowShown;
          binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel,
              (call) async {
            if (call.method == 'isMinimized') return false;
            if (call.method == 'setSkipTaskbar' && !windowShown.isCompleted) {
              windowShown.complete();
            }
            return null;
          });
          addTearDown(() => binding.defaultBinaryMessenger
              .setMockMethodCallHandler(windowChannel, null));
          globalState.config = Config(
              themeProps: defaultThemeProps,
              networkProps: NetworkProps(systemProxy: mode),
              appSetting:
                  AppSettingProps(autoRun: autoRun, disclaimerAccepted: true));
          final actions = _ProxyActions();
          late _InitializationController controller;
          var created = false;
          await tester.pumpWidget(ProviderScope(
              child: MaterialApp(home: Consumer(builder: (context, ref, _) {
            ref.watch(networkSettingProvider);
            ref.watch(profilesProvider);
            ref.watch(currentProfileIdProvider);
            ref.watch(appSettingProvider);
            if (!created) {
              controller = _InitializationController(context, ref, actions);
              globalState.appController = controller;
              created = true;
            }
            return const ProxyManager(child: SizedBox());
          }))));
          final container = ProviderScope.containerOf(controller.context);
          await tester.runAsync(() async {
            // Complete the native-window boundary in the real async zone.
            windowShown = Completer<void>();
            final dir =
                await Directory.systemTemp.createTemp('entoma-startup-');
            final oldPaths = PathProviderPlatform.instance;
            PathProviderPlatform.instance = FixturePaths(dir.path);
            final oldData = appPath.dataDir;
            await oldData.future.timeout(const Duration(seconds: 2));
            appPath.dataDir = Completer<Directory>()..complete(dir);
            final oldCore = clashCore.clashInterface;
            final core = _ListenerCore(actions);
            clashCore.clashInterface = core;
            try {
              final profile = Profile(
                  id: 'startup', autoUpdateDuration: const Duration(days: 1));
              controller.setProfile(profile);
              container.read(currentProfileIdProvider.notifier).value =
                  profile.id;
              final file = File(await appPath.getProfilePath(profile.id));
              await file.parent.create(recursive: true);
              await file.writeAsString('fixture profile');
              final onError = FlutterError.onError;
              try {
                if (earlyIntent == null) {
                  await controller.init().timeout(const Duration(seconds: 3));
                } else {
                  final preparing = Completer<void>();
                  final release = Completer<void>();
                  controller.preparing = () async {
                    preparing.complete();
                    await release.future;
                  };
                  final initialization = controller.init();
                  await preparing.future.timeout(const Duration(seconds: 2));
                  await controller.setSystemProxyEnabled(earlyIntent);
                  release.complete();
                  await initialization.timeout(const Duration(seconds: 3));
                }
                await windowShown.future.timeout(const Duration(seconds: 2));
              } finally {
                FlutterError.onError = onError;
              }
              if (autoRun && earlyIntent == null) {
                await core.trafficRead.future
                    .timeout(const Duration(seconds: 2));
              }
              expect(core.starts, autoRun && earlyIntent == null ? 1 : 0);
              expect(actions.starts, earlyIntent == true ? 1 : 0,
                  reason:
                      'autoRun owns its core; proxy must not start it twice');
              expect(actions.writes, connects ? 1 : 0);
              expect(container.read(networkSettingProvider).systemProxy,
                  earlyIntent ?? mode);
              expect(actions.coordinator.desired, connects);
              expect(
                  actions.coordinator.phase,
                  connects
                      ? DesktopProxyPhase.connected
                      : DesktopProxyPhase.disconnected);
              expect(container.read(initProvider), true);
              if (autoRun && mode && earlyIntent == null) {
                await controller.updateStatus(false);
                expect(
                    actions.coordinator.phase, DesktopProxyPhase.disconnected);
                expect(actions.running, false);
                expect(container.read(networkSettingProvider).systemProxy, true,
                    reason: 'stopping the core preserves the next-start mode');
              }
            } finally {
              globalState.stopUpdateTasks();
              clashCore.clashInterface = oldCore;
              appPath.dataDir = oldData;
              PathProviderPlatform.instance = oldPaths;
              await dir.delete(recursive: true);
            }
          });
          await tester.pump();
          expect(actions.writes, connects ? 1 : 0,
              reason:
                  'init ready must not duplicate the explicit startup intent');
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        }, skip: !Platform.isMacOS && !Platform.isWindows);
      }
    }
  }

  testWidgets('default proxy preference and init ready do not connect',
      (tester) async {
    globalState.config = Config(themeProps: defaultThemeProps);
    final actions = _ProxyActions();
    final controller = await _mount(tester, actions,
        withManager: true,
        body: const SizedBox(width: 600, child: SystemProxyButton()));
    final container = ProviderScope.containerOf(controller.context);
    expect(container.read(appSettingProvider).autoRun, false);
    expect(container.read(networkSettingProvider).systemProxy, true);
    container.read(initProvider.notifier).value = true;
    await tester.pump();
    expect(actions.starts, 0);
    expect(actions.writes, 0);
    expect(actions.coordinator.desired, false);
    expect(container.read(trayStateProvider).systemProxy, false);
    expect(find.text('未连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isMacOS && !Platform.isWindows);

  testWidgets('external change cannot reconnect through settings or remount',
      (tester) async {
    globalState.config = Config(themeProps: defaultThemeProps);
    globalState.appState = globalState.appState.copyWith(isInit: true);
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    final actions = _ProxyActions();
    final controller = await _mount(tester, actions,
        body: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, visible, __) => visible
                ? const ProxyManager(child: SizedBox())
                : const SizedBox()));
    final container = ProviderScope.containerOf(controller.context);
    await controller.updateSystemProxy();
    await tester.pump();
    expect(actions.writes, 1);
    actions.applied = false; // External settings no longer match our proxy.
    await actions.coordinator.verify();
    expect(actions.coordinator.phase, DesktopProxyPhase.failed);
    expect(actions.coordinator.desired, false);
    expect(container.read(networkSettingProvider).systemProxy, true);
    expect(container.read(trayStateProvider).systemProxy, false);
    container
        .read(networkSettingProvider.notifier)
        .updateState((state) => state.copyWith(bypassDomain: ['new.example']));
    container.read(acceptedMixedPortProvider.notifier).state = 17891;
    await tester.pump();
    shown.value = false;
    await tester.pump();
    shown.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(actions.writes, 1);
    expect(actions.starts, 1);
    expect(actions.coordinator.phase, DesktopProxyPhase.failed);
    await controller
        .retrySystemProxy(); // Retry the failed off/recovery intent.
    expect(actions.writes, 1);
    expect(actions.coordinator.phase, DesktopProxyPhase.disconnected);
    await controller
        .updateSystemProxy(); // Tray uses session intent, not true pref.
    expect(actions.writes, 2);
    expect(actions.coordinator.phase, DesktopProxyPhase.connected);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isMacOS && !Platform.isWindows);

  testWidgets(
      'failed start needs explicit retry and setting changes do not retry',
      (tester) async {
    globalState.appState = globalState.appState.copyWith(isInit: true);
    final actions = _ProxyActions()..writeFailure = StateError('denied');
    final controller = await _mount(tester, actions, withManager: true);
    final container = ProviderScope.containerOf(controller.context);
    await controller.setSystemProxyEnabled(true);
    await tester.pump();
    expect(actions.writes, 1);
    expect(actions.coordinator.phase, DesktopProxyPhase.failed);
    expect(actions.coordinator.desired, true);
    container.read(acceptedMixedPortProvider.notifier).state = 17892;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(actions.writes, 1);
    actions.writeFailure = null;
    await controller.retrySystemProxy();
    expect(actions.writes, 2);
    expect(actions.coordinator.phase, DesktopProxyPhase.connected);
    container.read(networkSettingProvider.notifier).updateState(
        (state) => state.copyWith(bypassDomain: ['changed.example']));
    await tester.pump();
    expect(actions.writes, 3,
        reason: 'an established connection can reconfigure');
    await tester.pump(const Duration(seconds: 3));
    expect(actions.writes, 3,
        reason: 'observation must not form an apply loop');
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isMacOS && !Platform.isWindows);

  testWidgets(
      'real setup rollback failure unwinds one-click startup without self-wait',
      (tester) async {
    final actions = _ProxyActions();
    var controller = await _mount(tester, actions);
    late ClashHandlerInterface oldCore;
    final oldPaths = PathProviderPlatform.instance;
    final core = _RollbackCore();

    await tester.runAsync(() async {
      // Windows' TCP service can reach appPath before an awaited file-system
      // operation returns. Install paths before constructing that service;
      // otherwise the unmocked plugin leaves dataDir unresolved in this test.
      final directory =
          await Directory.systemTemp.createTemp('entoma-proxy-rollback-');
      PathProviderPlatform.instance = FixturePaths(directory.path);
      final oldData = appPath.dataDir;
      try {
        await oldData.future.timeout(const Duration(seconds: 2));
        oldCore = clashCore.clashInterface;
        clashCore.clashInterface = core;
        addTearDown(() => clashCore.clashInterface = oldCore);
        // Construct the configuration queue in the real async zone: a pending
        // Future.value created in FakeAsync cannot progress inside runAsync.
        controller = _Controller(controller.context, controller.fixtureRef)
          ..fixture = actions.coordinator;
        globalState.appController = controller;
        appPath.dataDir = Completer<Directory>()..complete(directory);
        final profile = Profile(
            id: 'one-click-fixture',
            autoUpdateDuration: const Duration(days: 1));
        controller.setProfile(profile);
        ProviderScope.containerOf(controller.context)
            .read(currentProfileIdProvider.notifier)
            .value = profile.id;
        final file = File(await appPath.getProfilePath(profile.id));
        await file.parent.create(recursive: true);
        await file.writeAsString('fixture profile');

        // This enters the real controller apply -> configuration queue ->
        // setupConfig rollback-failed handling from within the startup flight.
        actions.starting = () => controller.applyProfile(silence: true);
        await controller
            .setSystemProxyEnabled(true)
            .timeout(const Duration(seconds: 2), onTimeout: () {
          throw StateError('startup did not settle: configs=${core.configs}, '
              'setups=${core.setups}, events=${actions.events}, '
              'phase=${actions.coordinator.phase}');
        });

        expect(core.configs, 1);
        expect(core.setups, 1);
        expect(controller.manualStartCalls, 0);
        expect(actions.starts, 1);
        expect(actions.writes, 0);
        expect(actions.running, false);
        expect(actions.restores, 1);
        expect(actions.phases, contains(DesktopProxyPhase.failed));
        expect(actions.phases, isNot(contains(DesktopProxyPhase.connected)));
        expect(actions.coordinator.phase, DesktopProxyPhase.disconnected);
        expect(actions.coordinator.desired, false);
        expect(actions.events, ['start', 'stop', 'restore']);
        expect(
            ProviderScope.containerOf(controller.context)
                .read(networkSettingProvider)
                .systemProxy,
            false);
      } finally {
        appPath.dataDir = oldData;
        PathProviderPlatform.instance = oldPaths;
        await directory.delete(recursive: true);
      }
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'controller system-proxy toggle alone runs the shared coordinator',
      (tester) async {
    final actions = _ProxyActions();
    final controller = await _mount(tester, actions);
    await controller.updateSystemProxy();
    expect(actions.coordinator.phase, DesktopProxyPhase.connected);
    expect(actions.starts, 1);
    expect(actions.writes, 1);
    expect(controller.manualStartCalls, 0);
    expect(
        ProviderScope.containerOf(controller.context)
            .read(networkSettingProvider)
            .systemProxy,
        true);
    await controller.updateSystemProxy();
    expect(actions.coordinator.phase, DesktopProxyPhase.disconnected);
    expect(actions.restores, 1);
    expect(actions.running, false);
  });

  for (final surface in ['dashboard', 'network settings']) {
    testWidgets('$surface switch is one click and uses controller coordinator',
        (tester) async {
      final actions = _ProxyActions();
      globalState.appState = globalState.appState.copyWith(isInit: true);
      final controller = await _mount(tester, actions,
          withManager: true,
          body: surface == 'dashboard'
              ? const SizedBox(width: 600, child: SystemProxyButton())
              : SystemProxyItem());
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(actions.starts, 1);
      expect(actions.writes, 1);
      expect(actions.coordinator.phase, DesktopProxyPhase.connected);
      expect(controller.manualStartCalls, 0);
      expect(find.text('已连接'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(actions.restores, 1);
      expect(actions.running, false);
      expect(actions.coordinator.phase, DesktopProxyPhase.disconnected);
    }, skip: !Platform.isMacOS && !Platform.isWindows);
  }
}
