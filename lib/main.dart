import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/tile.dart';
import 'package:fl_clash/plugins/vpn.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application.dart';
import 'clash/core.dart';
import 'clash/lib.dart';
import 'common/common.dart';
import 'common/core_service_port.dart';
import 'models/models.dart';
import 'diagnostics/android_network_acceptance.dart';

Future<void> main() async {
  globalState.isService = false;
  WidgetsFlutterBinding.ensureInitialized(); // 确保 Flutter 绑定已初始化

  final version = await system.version;
  await clashCore.preload();
  await globalState.initApp(version);
  await android?.init();
  await window?.init(version); // 假设 window?.init(version) 是正确的调用
  HttpOverrides.global = FlClashHttpOverrides();

  // 注册 WidgetsBindingObserver 来监听应用生命周期事件

  runApp(ProviderScope(child: const Application()));
  if (Platform.isAndroid &&
      const bool.fromEnvironment('ENTOMA_NETWORK_ACCEPTANCE')) {
    unawaited(runAndroidNetworkAcceptance());
  }
}

@pragma('vm:entry-point')
Future<void> _service(List<String> flags) async {
  globalState.isService = true;
  WidgetsFlutterBinding.ensureInitialized();
  final quickStart = flags.contains("quick");
  final clashLibHandler = ClashLibHandler();
  await globalState.init();

  tile?.addListener(
    _TileListenerWithService(
      onStop: () async {
        await app?.tip(appLocalizations.stopVpn);
        clashLibHandler.stopListener();
        await vpn?.stop();
        exit(0);
      },
    ),
  );

  vpn?.handleGetStartForegroundParams = () {
    final traffic = clashLibHandler.getTraffic();
    return json.encode({
      "title": clashLibHandler.getCurrentProfileName(),
      "content": "$traffic",
    });
  };

  vpn?.addListener(
    _VpnListenerWithService(
      onDnsChanged: (String dns) {
        print("handle dns $dns");
        clashLibHandler.updateDns(dns);
      },
    ),
  );
  final quickReady = Completer<void>();
  _handleMainIpc(clashLibHandler, quickReady.future);
  if (quickStart) {
    commonPrint.log("quick start");
    Future(() async {
      await ClashCore.initGeo();
      app?.tip(appLocalizations.startVpn);
      final homeDirPath = await appPath.homeDirPath;
      final version = await system.version;
      final clashConfig = globalState.config.patchClashConfig.copyWith.tun(
        enable: true,
      );
      final profileId = globalState.config.currentProfileId;
      if (profileId == null) {
        return;
      }
      final params = await globalState.getSetupParams(pathConfig: clashConfig);
      final res = await clashLibHandler.quickStart(
        InitParams(homeDir: homeDirPath, version: version),
        params,
        globalState.getCoreState(),
      );
      debugPrint(res);
      if (res.isNotEmpty) {
        await vpn?.stop();
        return;
      }
      // Match the UI ordering. The service readiness barrier drains this work
      // before true exit sends its native stop request.
      if (!await clashLibHandler.startListener()) return;
      final started = await vpn?.start(clashLibHandler.getAndroidVpnOptions());
      if (started != true) await clashLibHandler.stopListener();
    }).whenComplete(() {
      if (!quickReady.isCompleted) quickReady.complete();
    }).catchError((Object error, StackTrace stack) {
      commonPrint.log('后台连接初始化失败：${error.runtimeType}');
    });
  } else {
    quickReady.complete();
  }
}

_handleMainIpc(ClashLibHandler clashLibHandler, Future<void> ready) {
  final binding = CoreServicePort(
    handleAction: (message) => clashLibHandler.invokeAction(message),
    waitForReady: () => ready,
    attachMessagePort: (port) =>
        clashLibHandler.attachMessagePort(port.nativePort),
  );
  IsolateNameServer.removePortNameMapping(coreServiceIsolate);
  IsolateNameServer.registerPortWithName(binding.sendPort, coreServiceIsolate);
  final sendPort = IsolateNameServer.lookupPortByName(mainIsolate);
  if (sendPort != null) binding.attach(sendPort);
}

@immutable
class _TileListenerWithService with TileListener {
  final Function() _onStop;

  const _TileListenerWithService({required Function() onStop})
      : _onStop = onStop;

  @override
  void onStop() {
    _onStop();
  }
}

@immutable
class _VpnListenerWithService with VpnListener {
  final Function(String dns) _onDnsChanged;

  const _VpnListenerWithService({required Function(String dns) onDnsChanged})
      : _onDnsChanged = onDnsChanged;

  @override
  void onDnsChanged(String dns) {
    super.onDnsChanged(dns);
    _onDnsChanged(dns);
  }
}
