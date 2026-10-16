import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/state.dart';

import 'generated/clash_ffi.dart';
import 'interface.dart';

class ClashLib extends ClashHandlerInterface with AndroidClashInterface {
  static ClashLib? _instance;
  Completer<bool> _canSendCompleter = Completer();
  SendPort? sendPort;
  final receiverPort = ReceivePort();
  bool _listening = false;
  Future<void>? _initializing;

  ClashLib._internal() {
    _initService().catchError((Object error, StackTrace stack) {
      if (!_canSendCompleter.isCompleted) {
        _canSendCompleter.completeError(error, stack);
      }
    });
  }

  @override
  preload() {
    return _canSendCompleter.future;
  }

  Future<void> waitForServiceReady() async {
    await invoke<bool>(
      method: ActionMethod.getIsInit,
      onTimeout: () => throw StateError('后台启动尚未完成，请重试退出'),
    );
  }

  Future<void> _initService() =>
      _initializing ??= _attachService().whenComplete(() {
        _initializing = null;
      });

  Future<void> _attachService() async {
    // An active service engine owns the VPN. Reattach its private port rather
    // than destroying it when Android recreates only the foreground Activity.
    _registerMainPort(receiverPort.sendPort);
    if (!_listening) {
      _listening = true;
      receiverPort.listen((message) {
        if (message is SendPort) {
          sendPort = message;
          if (!_canSendCompleter.isCompleted) _canSendCompleter.complete(true);
        } else {
          handleResult(
            ActionResult.fromJson(json.decode(
              message,
            )),
          );
        }
      });
    }
    if (await service?.init() != true) {
      throw StateError('后台核心尚未可用');
    }
    // A newly created engine sends its initial handshake when it registers.
    // An already-running quick/background engine accepts this new UI port.
    IsolateNameServer.lookupPortByName(coreServiceIsolate)
        ?.send(receiverPort.sendPort);
  }

  _registerMainPort(SendPort sendPort) {
    IsolateNameServer.removePortNameMapping(mainIsolate);
    IsolateNameServer.registerPortWithName(sendPort, mainIsolate);
  }

  factory ClashLib() {
    _instance ??= ClashLib._internal();
    return _instance!;
  }

  @override
  destroy() async {
    return await service?.destroy() == true;
  }

  @override
  reStart() {
    return _initService();
  }

  @override
  Future<bool> shutdown() async {
    // The exit transaction destroys the service engine only after native VPN
    // stop and this core acknowledgement. Do not tear down its reply port here.
    return await super.shutdown();
  }

  @override
  sendMessage(String message) async {
    await _canSendCompleter.future;
    sendPort?.send(message);
  }

  // @override
  // Future<bool> stopTun() {
  //   return invoke<bool>(
  //     method: ActionMethod.stopTun,
  //   );
  // }

  @override
  Future<AndroidVpnOptions?> getAndroidVpnOptions() async {
    final res = await invoke<String>(
      method: ActionMethod.getAndroidVpnOptions,
    );
    if (res.isEmpty) {
      return null;
    }
    return AndroidVpnOptions.fromJson(json.decode(res));
  }

  @override
  Future<bool> updateDns(String value) {
    return invoke<bool>(
      method: ActionMethod.updateDns,
      data: value,
    );
  }

  @override
  Future<DateTime?> getRunTime() async {
    final runTimeString = await invoke<String>(
      method: ActionMethod.getRunTime,
    );
    if (runTimeString.isEmpty) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(int.parse(runTimeString));
  }

  @override
  Future<String> getCurrentProfileName() {
    return invoke<String>(
      method: ActionMethod.getCurrentProfileName,
    );
  }
}

class ClashLibHandler {
  static ClashLibHandler? _instance;

  late final ClashFFI clashFFI;

  late final DynamicLibrary lib;

  ClashLibHandler._internal() {
    lib = DynamicLibrary.open("libclash.so");
    clashFFI = ClashFFI(lib);
    clashFFI.initNativeApiBridge(
      NativeApi.initializeApiDLData,
    );
  }

  factory ClashLibHandler() {
    _instance ??= ClashLibHandler._internal();
    return _instance!;
  }

  Future<String> invokeAction(String actionParams) {
    final completer = Completer<String>();
    final receiver = ReceivePort();
    receiver.listen((message) {
      if (!completer.isCompleted) {
        completer.complete(message);
        receiver.close();
      }
    });
    final actionParamsChar = actionParams.toNativeUtf8().cast<Char>();
    clashFFI.invokeAction(
      actionParamsChar,
      receiver.sendPort.nativePort,
    );
    malloc.free(actionParamsChar);
    return completer.future;
  }

  attachMessagePort(int messagePort) {
    clashFFI.attachMessagePort(
      messagePort,
    );
  }

  updateDns(String dns) {
    final dnsChar = dns.toNativeUtf8().cast<Char>();
    clashFFI.updateDns(dnsChar);
    malloc.free(dnsChar);
  }

  setState(CoreState state) {
    final stateChar = json.encode(state).toNativeUtf8().cast<Char>();
    clashFFI.setState(stateChar);
    malloc.free(stateChar);
  }

  String getCurrentProfileName() {
    final currentProfileRaw = clashFFI.getCurrentProfileName();
    final currentProfile = currentProfileRaw.cast<Utf8>().toDartString();
    clashFFI.freeCString(currentProfileRaw);
    return currentProfile;
  }

  AndroidVpnOptions getAndroidVpnOptions() {
    final vpnOptionsRaw = clashFFI.getAndroidVpnOptions();
    final vpnOptions = json.decode(vpnOptionsRaw.cast<Utf8>().toDartString());
    clashFFI.freeCString(vpnOptionsRaw);
    return AndroidVpnOptions.fromJson(vpnOptions);
  }

  Traffic getTraffic() {
    final trafficRaw = clashFFI.getTraffic();
    final trafficString = trafficRaw.cast<Utf8>().toDartString();
    clashFFI.freeCString(trafficRaw);
    if (trafficString.isEmpty) {
      return Traffic();
    }
    return Traffic.fromMap(json.decode(trafficString));
  }

  Traffic getTotalTraffic(bool value) {
    final trafficRaw = clashFFI.getTotalTraffic();
    final trafficString = trafficRaw.cast<Utf8>().toDartString();
    clashFFI.freeCString(trafficRaw);
    if (trafficString.isEmpty) {
      return Traffic();
    }
    return Traffic.fromMap(json.decode(trafficString));
  }

  startListener() async {
    clashFFI.startListener();
    return true;
  }

  stopListener() async {
    clashFFI.stopListener();
    return true;
  }

  DateTime? getRunTime() {
    final runTimeRaw = clashFFI.getRunTime();
    final runTimeString = runTimeRaw.cast<Utf8>().toDartString();
    if (runTimeString.isEmpty) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(int.parse(runTimeString));
  }

  Future<Map<String, dynamic>> getConfig(String id) async {
    final path = await appPath.getProfilePath(id);
    final pathChar = path.toNativeUtf8().cast<Char>();
    final configRaw = clashFFI.getConfig(pathChar);
    final configString = configRaw.cast<Utf8>().toDartString();
    if (configString.isEmpty) {
      return {};
    }
    final config = json.decode(configString);
    malloc.free(pathChar);
    clashFFI.freeCString(configRaw);
    return config;
  }

  Future<String> quickStart(
    InitParams initParams,
    SetupParams setupParams,
    CoreState state,
  ) {
    final completer = Completer<String>();
    final receiver = ReceivePort();
    receiver.listen((message) {
      if (!completer.isCompleted) {
        completer.complete(message);
        receiver.close();
      }
    });
    final params = json.encode(setupParams);
    final initValue = json.encode(initParams);
    final stateParams = json.encode(state);
    final initParamsChar = initValue.toNativeUtf8().cast<Char>();
    final paramsChar = params.toNativeUtf8().cast<Char>();
    final stateParamsChar = stateParams.toNativeUtf8().cast<Char>();
    clashFFI.quickStart(
      initParamsChar,
      paramsChar,
      stateParamsChar,
      receiver.sendPort.nativePort,
    );
    malloc.free(initParamsChar);
    malloc.free(paramsChar);
    malloc.free(stateParamsChar);
    return completer.future;
  }
}

ClashLib? get clashLib =>
    Platform.isAndroid && !globalState.isService ? ClashLib() : null;

ClashLibHandler? get clashLibHandler =>
    Platform.isAndroid && globalState.isService ? ClashLibHandler() : null;
