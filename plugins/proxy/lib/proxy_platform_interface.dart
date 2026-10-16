import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'proxy_method_channel.dart';

class ProxyStatus {
  final bool available;
  final bool matches;
  final bool owned;
  final bool restorationPending;
  final bool usesListener;
  const ProxyStatus(
      {required this.available,
      required this.matches,
      required this.owned,
      required this.restorationPending,
      this.usesListener = false});

  factory ProxyStatus.fromMap(Map<dynamic, dynamic> value) {
    for (final key in ['available', 'matches', 'owned', 'restorationPending']) {
      if (value[key] is! bool) throw StateError('Invalid native proxy status');
    }
    if (value['usesListener'] is! bool) {
      throw StateError('Invalid native listener ownership status');
    }
    return ProxyStatus(
        available: value['available'],
        matches: value['matches'],
        owned: value['owned'],
        restorationPending: value['restorationPending'],
        usesListener: value['usesListener']);
  }
}

abstract class ProxyPlatform extends PlatformInterface {
  /// Constructs a ProxyPlatform.
  ProxyPlatform() : super(token: _token);

  static final Object _token = Object();

  static ProxyPlatform _instance = MethodChannelProxy();

  /// The default instance of [ProxyPlatform] to use.
  ///
  /// Defaults to [MethodChannelProxy].
  static ProxyPlatform get instance => _instance;

  static set instance(ProxyPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool?> startProxy(int port, List<String> bypassDomain) {
    throw UnimplementedError('startProxy() has not been implemented.');
  }

  Future<bool?> stopProxy() {
    throw UnimplementedError('stopProxy() has not been implemented.');
  }

  Future<ProxyStatus> getProxyStatus(int port, List<String> bypassDomain) {
    throw UnimplementedError('Native system proxy readback unavailable');
  }

  /// macOS auto-DNS shares the native network authorization and ownership queue.
  Future<bool?> startAutoDns() async => true;

  Future<bool?> stopAutoDns() async => true;
}
