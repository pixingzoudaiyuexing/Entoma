import 'dart:async';
import 'dart:io';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/about.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class DeleteController extends AppController {
  final events = <String>[];
  Completer<void>? stopping;
  Completer<void>? cleaning;
  bool stopFails = false;
  DeleteController(super.context, super.ref);
  @override
  Future<void> updateStatus(bool value) async {
    events.add('stop');
    if (stopFails) throw StateError('stop failed');
    await stopping?.future;
    events.add('stopped');
  }

  @override
  Future<void> clearEffect(String id) async {
    events.add('clean');
    await cleaning?.future;
    events.add('cleaned');
  }
}

Profile fixture(String id) =>
    Profile(id: id, autoUpdateDuration: const Duration(hours: 1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await AppLocalizations.load(const Locale('en'));
    globalState.config = Config(themeProps: defaultThemeProps);
    globalState.packageInfo = PackageInfo(
        appName: 'Entoma',
        packageName: 'com.entoma.client',
        version: '0.1.0',
        buildNumber: '1');
  });
  Future<DeleteController> mountDelete(
      WidgetTester tester, List<Profile> profiles) async {
    globalState.config = Config(
        themeProps: defaultThemeProps,
        profiles: profiles,
        currentProfileId: 'a');
    late DeleteController controller;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Consumer(builder: (context, ref, _) {
      ref.watch(profilesProvider);
      ref.watch(currentProfileIdProvider);
      controller = DeleteController(context, ref);
      return const Scaffold();
    }))));
    return controller;
  }

  testWidgets(
      'delete waits for stop and cleanup; failed stop preserves profile',
      (tester) async {
    final controller = await mountDelete(tester, [fixture('a')]);
    controller.stopFails = true;
    await expectLater(controller.deleteProfile('a'), throwsStateError);
    expect(globalState.config.profiles.map((p) => p.id), ['a']);
    expect(controller.events, ['stop']);
    controller.events.clear();
    controller.stopFails = false;
    controller.stopping = Completer();
    controller.cleaning = Completer();
    var done = false;
    final deletion = controller.deleteProfile('a').then((_) => done = true);
    await tester.pump();
    expect(done, false);
    expect(controller.events, ['stop']);
    controller.stopping!.complete();
    await tester.pump();
    expect(controller.events, ['stop', 'stopped', 'clean']);
    expect(done, false);
    controller.cleaning!.complete();
    await deletion;
    expect(globalState.config.profiles, isEmpty);
    expect(globalState.config.currentProfileId, isNull);
  });
  testWidgets('delete cleanup preserves a later user selection',
      (tester) async {
    final controller =
        await mountDelete(tester, [fixture('a'), fixture('b'), fixture('c')]);
    controller.cleaning = Completer();
    final deletion = controller.deleteProfile('a');
    await tester.pump();
    final container = ProviderScope.containerOf(controller.context);
    container.read(currentProfileIdProvider.notifier).value = 'c';
    controller.cleaning!.complete();
    await deletion;
    expect(globalState.config.currentProfileId, 'c');
    expect(globalState.config.profiles.map((p) => p.id), ['b', 'c']);
    expect(controller.events, ['clean', 'cleaned']);
  });
  testWidgets(
      'clearEffect deletes profile and provider directory before completion',
      (tester) async {
    late AppController controller;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Consumer(builder: (context, ref, _) {
      controller = AppController(context, ref);
      return const Scaffold();
    }))));
    await tester.runAsync(() async {
      final directory =
          await Directory.systemTemp.createTemp('entoma-delete-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => directory.path);
      final old = appPath.dataDir;
      await old.future;
      appPath.dataDir = Completer<Directory>()..complete(directory);
      try {
        final profile = File(await appPath.getProfilePath('a'));
        await profile.parent.create(recursive: true);
        await profile.writeAsString('fixture');
        final providerDir = Directory(await appPath.getProvidersDirPath('a'));
        await providerDir.create(recursive: true);
        await File('${providerDir.path}/fixture').writeAsString('fixture');
        final neighbor = File(await appPath.getProfilePath('b'));
        await neighbor.writeAsString('keep');
        await controller.clearEffect('a');
        expect(await profile.exists(), false);
        expect(await providerDir.exists(), false);
        expect(await neighbor.readAsString(), 'keep');
      } finally {
        appPath.dataDir = old;
        await directory.delete(recursive: true);
      }
    });
  });

  for (final mode in ['latest', 'failed', 'dispose-query']) {
    testWidgets('About uses Entoma release source: $mode', (tester) async {
      var queries = 0;
      final blocked = Completer<Map<String, dynamic>?>();
      final showAbout = ValueNotifier(true);
      addTearDown(showAbout.dispose);
      await tester.pumpWidget(ProviderScope(
          overrides: [
            releaseUpdateCheckProvider.overrideWithValue(() async {
              queries++;
              if (mode == 'failed') throw StateError('offline');
              if (mode == 'dispose-query') return blocked.future;
              return null;
            })
          ],
          child: MaterialApp(
              home: CommonScaffold(
                  title: "About",
                  body: ValueListenableBuilder<bool>(
                      valueListenable: showAbout,
                      builder: (_, value, __) => value
                          ? const AboutView()
                          : const Text('other page'))))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(appLocalizations.checkUpdate));
      await tester.tap(find.text(appLocalizations.checkUpdate));
      await tester.pump();
      if (mode == 'dispose-query') {
        showAbout.value = false;
        await tester.pump();
        blocked.complete(null);
      }
      await tester.pumpAndSettle();
      expect(queries, 1);
      expect(find.text('已是最新版本'),
          mode == 'latest' ? findsOneWidget : findsNothing);
      if (mode == 'failed') {
        expect(find.text('检查更新失败，请检查网络后重试'), findsOneWidget);
        showAbout.value = false;
        await tester.pump();
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(queries, 1);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
