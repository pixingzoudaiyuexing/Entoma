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
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:fl_clash/views/dashboard/widgets/quick_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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

Future<_Controller> _mount(WidgetTester tester, _ProxyActions actions,
    {Widget body = const SizedBox.shrink()}) async {
  late _Controller controller;
  var created = false;
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: Consumer(builder: (context, ref, _) {
      ref.watch(profilesProvider);
      ref.watch(currentProfileIdProvider);
      ref.watch(networkSettingProvider);
      ref.watch(patchClashConfigProvider);
      if (!created) {
        controller = _Controller(context, ref)..fixture = actions.coordinator;
        globalState.appController = controller;
        globalState.theme = CommonTheme.of(context, 1);
        globalState.measure = Measure.of(context, 1);
        created = true;
      }
      return Scaffold(body: body);
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

  testWidgets(
      'real setup rollback failure unwinds one-click startup without self-wait',
      (tester) async {
    final actions = _ProxyActions();
    var controller = await _mount(tester, actions);
    late ClashHandlerInterface oldCore;
    final oldPaths = PathProviderPlatform.instance;
    final core = _RollbackCore();
    addTearDown(() => clashCore.clashInterface = oldCore);

    await tester.runAsync(() async {
      oldCore = clashCore.clashInterface;
      clashCore.clashInterface = core;
      // Construct the configuration queue in the real async zone: a pending
      // Future.value created in FakeAsync cannot progress inside runAsync.
      controller = _Controller(controller.context, controller.fixtureRef)
        ..fixture = actions.coordinator;
      globalState.appController = controller;
      final directory =
          await Directory.systemTemp.createTemp('entoma-proxy-rollback-');
      PathProviderPlatform.instance = FixturePaths(directory.path);
      final oldData = appPath.dataDir;
      await oldData.future;
      appPath.dataDir = Completer<Directory>()..complete(directory);
      try {
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
      final controller = await _mount(tester, actions,
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
