import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AndroidExitFixtureController extends AppController {
  AndroidExitFixtureController(super.context, super.ref);

  final calls = <String>[];
  Completer<bool>? stopHold;
  Completer<void>? saveHold;
  bool saveFails = false;
  bool useRealPreferenceSave = false;
  bool stopAccepted = true;
  bool shutdownAccepted = true;
  bool destroyAccepted = true;

  @override
  bool get usesAndroidExit => true;

  @override
  Future<void> androidPrepareForExit() async => calls.add('prepare');

  @override
  Future<void> savePreferences() async {
    calls.add('save');
    if (saveFails) throw StateError('fixture save failed');
    if (useRealPreferenceSave) {
      await super.savePreferences();
      return;
    }
    await saveHold?.future;
  }

  @override
  Future<bool> androidStopVpn() async {
    calls.add('stop-vpn');
    return stopHold != null ? await stopHold!.future : stopAccepted;
  }

  @override
  Future<bool> androidShutdownCore() async {
    calls.add('shutdown-core');
    return shutdownAccepted;
  }

  @override
  Future<bool> androidDestroyEngine() async {
    calls.add('destroy-engine');
    return destroyAccepted;
  }

  @override
  Future<void> androidCancelExit() async => calls.add('cancel');

  @override
  Future<void> androidFinishExit() async {
    calls.add('activity-pop');
    await SystemNavigator.pop();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final systemCalls = <MethodCall>[];
  final windowCalls = <MethodCall>[];

  setUp(() async {
    await AppLocalizations.load(const Locale('en'));
    globalState.config = Config(
        themeProps: defaultThemeProps,
        appSetting: const AppSettingProps(minimizeOnExit: false));
    globalState.appState = AppState(
        viewSize: Size.zero,
        version: 29,
        requests: FixedList<Connection>(10),
        logs: FixedList<Log>(10),
        traffics: FixedList<Traffic>(10),
        totalTraffic: Traffic());
    systemCalls.clear();
    windowCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      systemCalls.add(call);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'),
            (call) async {
      windowCalls.add(call);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  Future<AndroidExitFixtureController> mount(WidgetTester tester) async {
    AndroidExitFixtureController? controller;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Consumer(builder: (context, ref, _) {
      controller ??= AndroidExitFixtureController(context, ref);
      globalState.appController = controller!;
      return Scaffold(
          body: TextButton(
              onPressed: () async => await controller!.handleBackOrExit(),
              child: const Text('Back')));
    }))));
    return controller!;
  }

  testWidgets(
      'real handleExit calls VPN cleanup before engine and Activity pop',
      (tester) async {
    final controller = await mount(tester);
    await controller.handleExit();
    expect(
        controller.calls,
        containsAllInOrder(
            ['stop-vpn', 'shutdown-core', 'destroy-engine', 'activity-pop']));
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1));
    expect(controller.isClosing, isTrue);
  });

  testWidgets(
      'real Android exit holds Activity and engine after old 300 ms deadline',
      (tester) async {
    final controller = await mount(tester);
    controller.stopHold = Completer<bool>();
    final result = controller.handleExit();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(controller.calls, contains('stop-vpn'));
    expect(controller.calls, isNot(contains('shutdown-core')));
    expect(controller.calls, isNot(contains('destroy-engine')));
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty);
    controller.stopHold!.complete(true);
    await tester.pump();
    await result;
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1));
  });

  testWidgets(
      'duplicate actual Back exits produce only one VPN and Activity close',
      (tester) async {
    final controller = await mount(tester);
    controller.stopHold = Completer<bool>();
    final first = controller.handleBackOrExit();
    final second = controller.handleBackOrExit();
    await tester.pump();
    expect(controller.calls.where((call) => call == 'prepare'), hasLength(1));
    expect(controller.calls.where((call) => call == 'stop-vpn'), hasLength(1));
    controller.stopHold!.complete(true);
    await tester.pump();
    await first;
    await second;
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1));
  });

  testWidgets(
      'failed VPN acknowledgement keeps Activity and engine available for retry',
      (tester) async {
    final controller = await mount(tester);
    controller.stopAccepted = false;
    await controller.handleExit();
    expect(controller.calls, contains('cancel'));
    expect(controller.calls, isNot(contains('destroy-engine')));
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty);
    expect(controller.isClosing, isFalse);
    controller.stopAccepted = true;
    await controller.handleExit();
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1));
  });

  testWidgets(
      'unknown core shutdown keeps admission closed until explicit exit retry',
      (tester) async {
    final controller = await mount(tester);
    controller.shutdownAccepted = false;
    await controller.handleExit();
    expect(controller.calls, contains('shutdown-core'));
    expect(controller.calls, isNot(contains('cancel')));
    expect(controller.calls, isNot(contains('destroy-engine')));
    expect(controller.isClosing, isTrue);
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty);
    var newOperationRan = false;
    await expectLater(controller.runProfileTransaction(() async {
      newOperationRan = true;
    }), throwsStateError);
    expect(newOperationRan, isFalse);
    await controller.updateStatus(true);
    expect(controller.calls.where((call) => call == 'prepare'), hasLength(1));
    controller.shutdownAccepted = true;
    await controller.handleExit();
    expect(
        controller.calls,
        containsAllInOrder(
            ['shutdown-core', 'destroy-engine', 'activity-pop']));
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1));
  });

  testWidgets('preference failure preserves runtime and a later exit can retry',
      (tester) async {
    final controller = await mount(tester);
    controller.saveFails = true;
    await controller.handleExit();
    expect(controller.calls, isNot(contains('shutdown-core')));
    expect(controller.calls, isNot(contains('destroy-engine')));
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty);
    expect(controller.isClosing, isFalse);
    controller.saveFails = false;
    await controller.handleExit();
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1));
  });

  testWidgets('real Preferences false result retains VPN, engine and Activity',
      (tester) async {
    final controller = await mount(tester);
    controller.useRealPreferenceSave = true;
    SharedPreferences.setMockInitialValues({});
    final originalPreferences = preferences.sharedPreferencesCompleter;
    // Let the singleton finish its existing initialization before replacing
    // only this test's dependency. No platform preference or Journal is changed.
    await tester.runAsync(() async => await originalPreferences.future);
    preferences.sharedPreferencesCompleter = Completer()..complete(null);
    try {
      await controller.handleExit();
      expect(
          controller.calls, containsAllInOrder(['prepare', 'save', 'cancel']));
      expect(controller.calls, isNot(contains('stop-vpn')));
      expect(controller.calls, isNot(contains('shutdown-core')));
      expect(controller.calls, isNot(contains('destroy-engine')));
      expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
          isEmpty);
      expect(controller.isClosing, isFalse);
    } finally {
      preferences.sharedPreferencesCompleter = originalPreferences;
    }
  });

  testWidgets('exit drains admitted profile transaction and rejects later work',
      (tester) async {
    final controller = await mount(tester);
    final admitted = Completer<void>();
    final entered = Completer<void>();
    final transaction = controller.runProfileTransaction(() async {
      entered.complete();
      await admitted.future;
    });
    await entered.future;
    final exit = controller.handleExit();
    await tester.pump();
    expect(controller.isClosing, isTrue);
    var rejectedExecuted = false;
    await expectLater(controller.runProfileTransaction(() async {
      rejectedExecuted = true;
    }), throwsStateError);
    expect(rejectedExecuted, isFalse);
    expect(controller.calls, isNot(contains('stop-vpn')));
    admitted.complete();
    await tester.pump();
    await transaction;
    await exit;
    expect(
        controller.calls,
        containsAllInOrder(
            ['stop-vpn', 'shutdown-core', 'destroy-engine', 'activity-pop']));
  });

  testWidgets(
      'new connect request during exit cannot establish another listener',
      (tester) async {
    final controller = await mount(tester);
    controller.stopHold = Completer<bool>();
    final exit = controller.handleExit();
    await tester.pump();
    // With no configured profile, admission would throw before native start.
    // A closing controller must reject the request before even that work.
    await controller.updateStatus(true);
    expect(controller.calls.where((call) => call == 'prepare'), hasLength(1));
    expect(controller.calls, isNot(contains('activity-pop')));
    controller.stopHold!.complete(true);
    await tester.pump();
    await exit;
  });

  testWidgets('minimize Back preserves VPN and never enters exit transaction',
      (tester) async {
    final controller = await mount(tester);
    ProviderScope.containerOf(controller.context)
        .read(appSettingProvider.notifier)
        .updateState((state) => state.copyWith(minimizeOnExit: true));
    await controller.handleBackOrExit();
    expect(controller.calls, isNot(contains('prepare')));
    expect(controller.calls, isNot(contains('stop-vpn')));
    expect(controller.calls, isNot(contains('destroy-engine')));
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty);
    expect(controller.isClosing, isFalse);
    // The host desktop Window.hide render throttler owns a five-second timer.
    // Advancing fake time settles that host-only side effect without sleeping.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('existing business Back block still prevents true exit',
      (tester) async {
    final controller = await mount(tester);
    controller.backBlock();
    await controller.handleBackOrExit();
    expect(controller.calls, isEmpty);
    expect(controller.isClosing, isFalse);
    expect(systemCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty);
  });
}
