import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/pop_scope.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class ExitRecordingController extends AppController {
  int exits = 0;
  ExitRecordingController(super.context, super.ref);
  @override
  Future<void> handleExit() async {
    exits++;
  }
  @override
  void unBackBlock() {
    // The fixture's Consumer is disposed when the test host is replaced.
    // The real app controller outlives its search subtree.
    if (context.mounted) super.unBackBlock();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  });

  Future<ExitRecordingController> mount(WidgetTester tester,
      {required TargetPlatform platform,
      bool hardBlock = false,
      bool edit = false}) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    final key = GlobalKey<CommonScaffoldState>();
    late ExitRecordingController controller;
    await tester.pumpWidget(ProviderScope(child: MaterialApp(
      home: Consumer(builder: (context, ref, _) {
        ref.watch(backBlockProvider);
        ref.watch(appSettingProvider);
        controller = ExitRecordingController(context, ref);
        globalState.appController = controller;
        final scaffold = CommonScaffold(
            key: key,
            title: 'Logs',
            body: TextButton(
                onPressed: controller.handleBackOrExit,
                child: const Text('Desktop close')));
        return hardBlock ? SystemBackBlock(child: scaffold) : scaffold;
      }),
    )));
    await tester.pump();
    key.currentState!.updateSearchState(
        (_) => AppBarSearchState(isSearch: true, onSearch: (_) {}));
    if (edit)
      key.currentState!
          .updateEditState((_) => AppBarEditState(isEdit: true, onExit: () {}));
    await tester.pump();
    await tester.pump();
    return controller;
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux
  ]) {
    testWidgets('$platform search permits desktop close through existing exit',
        (tester) async {
      final controller = await mount(tester, platform: platform);
      await tester.tap(find.text('Desktop close'));
      await tester.pump();
      expect(controller.exits, 1);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  testWidgets('desktop search preserves independent hard return protection',
      (tester) async {
    final controller =
        await mount(tester, platform: TargetPlatform.windows, hardBlock: true);
    await tester.tap(find.text('Desktop close'));
    await tester.pump();
    expect(controller.exits, 0);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('desktop editing keeps the existing return protection',
      (tester) async {
    final controller =
        await mount(tester, platform: TargetPlatform.windows, edit: true);
    await tester.tap(find.text('Desktop close'));
    await tester.pump();
    expect(controller.exits, 0);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('Android Back exits search without exiting the application',
      (tester) async {
    final controller = await mount(tester, platform: TargetPlatform.android);
    expect(find.byType(TextField), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Logs'), findsOneWidget);
    expect(controller.exits, 0);
    debugDefaultTargetPlatformOverride = null;
  });
}
