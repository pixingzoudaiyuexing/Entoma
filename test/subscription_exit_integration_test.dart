import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/clash/clash.dart';
import 'package:fl_clash/clash/interface.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:fl_clash/solution/subscription.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'legacy_entry_regression_test.dart' show FixturePaths;
import 'solution_test.dart' show MemoryVault, accountResponse, success;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class ValidationHoldCore implements ClashHandlerInterface {
  final validationStarted = Completer<void>();
  final resumeValidation = Completer<void>();
  int setupCalls = 0;
  void Function()? onGetConfig;
  bool failFirstSetup = false;
  final setupStarted = Completer<void>();
  Completer<void>? setupHold;
  @override
  Future<String> validateConfig(String data) async {
    validationStarted.complete();
    await resumeValidation.future;
    return '';
  }

  @override
  Future<bool> forceGc() async => true;
  @override
  Future<Map> getProxies() async => {
        'GLOBAL': {'name': 'GLOBAL', 'type': 'Selector', 'all': <String>[]}
      };
  @override
  Future<Result> getConfig(String path) async {
    onGetConfig?.call();
    return Result.success(<String, dynamic>{});
  }

  @override
  Future<String> getExternalProviders() async => '';
  @override
  Future<String> setupConfig(SetupParams params) async {
    setupCalls++;
    if (!setupStarted.isCompleted) setupStarted.complete();
    if (setupHold != null) await setupHold!.future;
    if (failFirstSetup && setupCalls == 1) return 'fixture setup failed';
    return '';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ClosingController extends AppController {
  bool closing = false;
  int saves = 0;
  final saveStarted = Completer<void>();
  Completer<void>? saveHold;
  ClosingController(super.context, super.ref);
  @override
  bool get isClosing => closing;
  @override
  Future<void> savePreferences() async {
    saves++;
    if (!saveStarted.isCompleted) saveStarted.complete();
    if (saveHold != null) await saveHold!.future;
  }
}

class FixtureApi extends SolutionApi {
  final String yaml;
  FixtureApi(this.yaml)
      : super(client: MockClient((r) async {
          if (r.url.path == '/api/v1/subscription') {
            return success({
              'eligible': true,
              'accessUrl': '$solutionOrigin/fixture-config'
            });
          }
          return accountResponse(r);
        }));
  @override
  Future<Object?> call(String path,
      {String method = 'GET',
      String? token,
      Map<String, dynamic>? body}) async {
    if (path == '/api/v1/subscription') {
      return {'eligible': true, 'accessUrl': '$solutionOrigin/fixture-config'};
    }
    return super.call(path, method: method, token: token, body: body);
  }

  @override
  Future<Uint8List> download(String url) async =>
      Uint8List.fromList(utf8.encode(yaml));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'before-admission',
    'admitted-commit',
    'admitted-rollback',
    'admitted-exit-drain'
  ]) {
    testWidgets('subscription versus macOS exit: $scenario', (tester) async {
      await AppLocalizations.load(const Locale('en'));
      late ValidationHoldCore core;
      late ClashHandlerInterface originalCore;
      addTearDown(() {
        clashCore.clashInterface = originalCore;
      });
      late Directory directory;
      late String oldPath;
      final oldPaths = PathProviderPlatform.instance;
      Completer<Directory>? originalData;
      await tester.runAsync(() async {
        core = ValidationHoldCore();
        originalCore = clashCore.clashInterface;
        clashCore.clashInterface = core;
        directory =
            await Directory.systemTemp.createTemp('entoma-exit-refresh-');
        PathProviderPlatform.instance = FixturePaths(directory.path);
        originalData = appPath.dataDir;
        await originalData!.future;
        appPath.dataDir = Completer<Directory>()..complete(directory);
      });
      addTearDown(() async {
        appPath.dataDir = originalData!;
        PathProviderPlatform.instance = oldPaths;
        await directory.delete(recursive: true);
      });
      const candidate =
          '{"proxies":[{"name":"fixture","type":"ss","server":"example.invalid","port":443,"cipher":"aes-128-gcm","password":"fixture-only"}],"proxy-groups":[{"name":"select","type":"select","proxies":["fixture"]}],"rules":["MATCH,select"]}';
      final api = FixtureApi(candidate);
      addTearDown(api.close);
      final session = SolutionSession(api, MemoryVault());
      await session.authenticate('fixture@example.com', 'fixture-password');
      globalState.config = Config(
          themeProps: defaultThemeProps,
          patchClashConfig: const ClashConfig(tun: Tun(enable: false)));
      globalState.appState = AppState(
          viewSize: Size.zero,
          version: 29,
          requests: FixedList<Connection>(10),
          logs: FixedList<Log>(10),
          traffics: FixedList<Traffic>(10),
          totalTraffic: Traffic());
      late ClosingController controller;
      late BuildContext controllerContext;
      late WidgetRef controllerRef;
      late SolutionSubscription subscription;
      await tester.pumpWidget(ProviderScope(
          overrides: [solutionSessionProvider.overrideWith((_) => session)],
          child: MaterialApp(home: Consumer(builder: (context, ref, _) {
            ref.watch(profilesProvider);
            ref.watch(currentProfileIdProvider);
            controllerContext = context;
            controllerRef = ref;
            subscription = ref.read(solutionSubscriptionProvider);
            return const Scaffold();
          }))));
      await tester.runAsync(() async {
        controller = ClosingController(controllerContext, controllerRef);
        globalState.appController = controller;
        final id = subscription.profileId(session);
        final previous = Profile(
            id: id,
            label: 'previous',
            autoUpdateDuration: const Duration(days: 1));
        controller.setProfile(previous);
        ProviderScope.containerOf(controller.context)
            .read(currentProfileIdProvider.notifier)
            .value = id;
        oldPath = await appPath.getProfilePath(id);
        await File(oldPath).parent.create(recursive: true);
        await File(oldPath).writeAsString('last known good');
        final refresh = subscription.refresh();
        refresh.catchError((Object _) {});
        await core.validationStarted.future;
        Future<void>? exitFlight;
        var nativeRestores = 0;
        const proxyChannel = MethodChannel('proxy');
        if (scenario == 'admitted-exit-drain') {
          core.setupHold = Completer<void>();
          controller.saveHold = Completer<void>();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(proxyChannel, (call) async {
            nativeRestores++;
            return false; // A failed restore keeps the test application alive.
          });
          addTearDown(() => TestDefaultBinaryMessengerBinding
              .instance.defaultBinaryMessenger
              .setMockMethodCallHandler(proxyChannel, null));
        }
        if (scenario == 'before-admission') {
          controller.closing = true;
        } else {
          core.onGetConfig = () {
            controller.closing = true;
            if (scenario == 'admitted-exit-drain') {
              exitFlight = controller.handleExit();
            }
          };
        }
        core.failFirstSetup = scenario == 'admitted-rollback';
        core.resumeValidation.complete();
        if (scenario == 'admitted-exit-drain') {
          await core.setupStarted.future;
          expect(nativeRestores, 0,
              reason: 'Native cleanup must wait for admitted profile load');
          await expectLater(
              controller.runProfileTransaction(() async {}), throwsStateError);
          core.setupHold!.complete();
          await controller.saveStarted.future;
          await Future<void>.delayed(Duration.zero);
          expect(nativeRestores, 0,
              reason: 'Exit must also wait for durable profile save');
          controller.saveHold!.complete();
        }
        if (scenario == 'admitted-commit' ||
            scenario == 'admitted-exit-drain') {
          await refresh;
          expect(await File(oldPath).readAsString(), contains('fixture'));
          expect(core.setupCalls, 1);
          expect(controller.saves, 1);
          if (scenario == 'admitted-exit-drain') {
            await exitFlight;
            expect(nativeRestores, 2);
          }
        } else {
          await expectLater(refresh, throwsA(anything));
          expect(await File(oldPath).readAsString(), 'last known good');
          expect(globalState.config.currentProfile?.label, 'previous');
          expect(controller.saves, 0);
          expect(core.setupCalls, scenario == 'admitted-rollback' ? 2 : 0);
        }
        expect(await File('$oldPath.previous').exists(), false);
        await expectLater(
            controller.applyProfile(silence: true), throwsStateError);
        debouncer.cancel(FunctionTag.addCheckIpNum);
        controller.closing = false;
      });
    }, skip: !Platform.isMacOS);
  }
}
