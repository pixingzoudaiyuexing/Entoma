import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy.dart';
import 'package:proxy/proxy_method_channel.dart';
import 'package:proxy/proxy_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = ProxyPlatform.instance;
  final channel = MethodChannelProxy();
  final calls = <String>[];

  setUp(() {
    calls.clear();
    ProxyPlatform.instance = channel;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async {
      calls.add(call.method);
      return true;
    });
  });
  tearDown(() {
    ProxyPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, null);
  });

  test(
      'macOS DNS restore reaches native ownership even without a Dart start flag',
      () async {
    final proxy = Proxy.forPlatform('macos');
    expect(await proxy.stopAutoDns(), isTrue);
    expect(await proxy.startAutoDns(), isTrue);
    expect(await proxy.stopAutoDns(), isTrue);
    expect(calls, ['StopAutoDns', 'StartAutoDns', 'StopAutoDns']);
  });

  test('other platform DNS calls are no-ops', () async {
    for (final platform in ['windows', 'linux', 'android']) {
      final proxy = Proxy.forPlatform(platform);
      expect(await proxy.startAutoDns(), isTrue);
      expect(await proxy.stopAutoDns(), isTrue);
    }
    expect(calls, isEmpty);
  });

  test('native permission cancellation remains a failure and can be retried',
      () async {
    var canceled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async {
        if (canceled) {
          throw PlatformException(code: 'NETWORK_PERMISSION_CANCELLED');
        }
      return true;
    });
    final proxy = Proxy.forPlatform('macos');
    await expectLater(proxy.startAutoDns(), throwsA(isA<PlatformException>()));
    canceled = false;
    expect(await proxy.startAutoDns(), isTrue);
  });
}
