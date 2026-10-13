import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:fl_clash/solution/subscription.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'solution_test.dart' show MemoryVault, accountResponse;
import 'legacy_entry_regression_test.dart' show FixturePaths;

class StartupController extends AppController {
  final WidgetRef widgetRef;
  bool nativeReady = false;
  bool prepareFails = false;
  bool ownershipFails = false;
  int initCalls = 0;
  int saves = 0;
  int applyCalls = 0;
  StartupController(BuildContext context, this.widgetRef)
      : super(context, widgetRef);
  @override
  Future<void> applyProfile({bool silence = false}) async {
    applyCalls++;
    if (ownershipFails) throw StateError('fixture account cleanup failed');
    if (!nativeReady) {
      throw StateError('fixture native GeoHome is not initialized');
    }
  }

  @override
  Future<void> prepareCore() async {
    if (prepareFails) throw StateError('fixture core preparation failed');
    nativeReady = true;
  }

  @override
  Future<void> init() async {
    initCalls++;
    nativeReady = true;
    await applyProfile(silence: true);
    widgetRef.read(initProvider.notifier).value = true;
  }

  @override
  Future<void> savePreferences() async {
    saves++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'cached',
    'already-ready',
    'prepare-failed',
    'ownership-failed',
    'storage-failed'
  ]) {
    final ready = scenario == 'already-ready';
    testWidgets('cold restore $scenario keeps account and gates core startup',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() async {
        final directory =
            await Directory.systemTemp.createTemp('entoma-cold-restore-test-');
        final oldPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = FixturePaths(directory.path);
        final originalData = appPath.dataDir;
        await originalData.future;
        appPath.dataDir = Completer<Directory>()..complete(directory);
        addTearDown(() async {
          appPath.dataDir = originalData;
          PathProviderPlatform.instance = oldPaths;
          await directory.delete(recursive: true);
        });
      });
      await AppLocalizations.load(const Locale('en'));
      final api =
          SolutionApi(client: MockClient((r) async => accountResponse(r)));
      addTearDown(api.close);
      final vault = MemoryVault()
        ..value = jsonEncode({
          'token': 'fixture-token',
          'email': 'fixture@example.com',
          'pending': []
        })
        ..journal = '{}';
      if (scenario == 'storage-failed') vault.value = 'invalid fixture JSON';
      final session = SolutionSession(api, vault);
      final id =
          'entoma-${sha256.convert(utf8.encode('${api.origin.origin}\nfixture@example.com'))}';
      globalState.config = Config(
          themeProps: defaultThemeProps,
          profiles: [
            Profile(
                id: id,
                label: 'Entoma subscription fixture',
                autoUpdateDuration: const Duration(days: 1))
          ],
          currentProfileId: id);
      globalState.appState = AppState(
          viewSize: Size.zero,
          version: 29,
          requests: FixedList<Connection>(10),
          logs: FixedList<Log>(10),
          traffics: FixedList<Traffic>(10),
          totalTraffic: Traffic());
      late StartupController controller;
      late SolutionSubscription subscription;
      await tester.pumpWidget(ProviderScope(
          overrides: [solutionSessionProvider.overrideWith((_) => session)],
          child: MaterialApp(home: Consumer(builder: (context, ref, _) {
            ref.watch(profilesProvider);
            ref.watch(currentProfileIdProvider);
            ref.watch(initProvider);
            controller = StartupController(context, ref)
              ..nativeReady = ready
              ..prepareFails = scenario == 'prepare-failed'
              ..ownershipFails = scenario == 'ownership-failed';
            subscription = ref.read(solutionSubscriptionProvider);
            return const Scaffold();
          }))));
      globalState.appController = controller;
      session.onAccountChange = subscription.keepOnly;
      await tester.runAsync(() async {
        if (scenario == 'cached' || scenario == 'already-ready') {
          await controller.restoreSessionAndInit(session);
          await session.refreshAccount();
          await Future<void>.delayed(Duration.zero);
          expect(controller.initCalls, 1);
          expect(globalState.appState.isInit, true);
        } else {
          await expectLater(
              controller.restoreSessionAndInit(session),
              scenario == 'storage-failed'
                  ? throwsA(isA<SolutionError>())
                  : throwsStateError);
          expect(controller.initCalls, 0);
          expect(globalState.appState.isInit, false);
          if (scenario != 'ownership-failed') expect(controller.saves, 0);
          if (scenario == 'prepare-failed' || scenario == 'storage-failed') {
            expect(controller.applyCalls, 0);
          }
        }
        expect(session.authenticated, scenario != 'storage-failed');
        expect(session.initialized, true);
        if (scenario == 'storage-failed') {
          expect(session.notice, isNotNull);
        } else {
          expect(session.notice, isNull);
        }
        expect(globalState.config.profiles.length, 1);
        expect(globalState.config.currentProfileId, id);
      });
    });
  }
}
