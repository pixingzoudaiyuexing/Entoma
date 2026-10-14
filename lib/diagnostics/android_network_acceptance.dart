// Opt-in real-device engineering harness. Ordinary builds tree-shake its entry.
// It never authenticates, pays, modifies business data or prints raw core DTOs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/clash/clash.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _service = MethodChannel('service');
void _record(Map<String, Object?> value) =>
    debugPrint('ENTOMA_NET ${jsonEncode({
          'at': DateTime.now().toUtc().toIso8601String(),
          ...value
        })}');

Future<Map<String, dynamic>> _snapshot() async => Map<String, dynamic>.from(
    await _service.invokeMethod<Map>('acceptanceSnapshot') ?? {});

Future<void> _wait(bool Function() ready, Duration limit) async {
  final until = DateTime.now().add(limit);
  while (!ready()) {
    if (DateTime.now().isAfter(until)) {
      throw TimeoutException('acceptance condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _stopAndConfirm() async {
  await globalState.appController.updateStatus(false);
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while ((await _snapshot())['vpnNetworks'] != 0) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('VPN did not stop');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<Map<String, Object?>> _probe(String node,
    {bool coreProxy = false}) async {
  final client = HttpClient()
    ..findProxy = (_) => coreProxy
        ? 'PROXY 127.0.0.1:${globalState.config.patchClashConfig.mixedPort}'
        : 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(Uri.parse(
        'https://www.cloudflare.com/cdn-cgi/trace?entoma_acceptance=android_matrix'));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    final raw =
        jsonDecode(await clashCore.clashInterface.getConnections()) as Map;
    final matching = (raw['connections'] as List? ?? [])
        .where((c) => (c['metadata'] as Map)['host'] == 'www.cloudflare.com')
        .toList();
    final chains =
        matching.map((c) => (c['chains'] as List).cast<String>()).toList();
    final bytes = await response.fold<int>(0, (a, b) => a + b.length);
    return {
      'http': response.statusCode,
      'bytes': bytes,
      'defaultTLS': true,
      'explicitProxy': coreProxy,
      'family': 'default',
      'selectedNodeObserved':
          chains.any((c) => c.contains(node) && !c.contains('DIRECT')),
      'inboundTypes':
          matching.map((c) => (c['metadata'] as Map)['type']).toSet().toList()
    };
  } catch (error) {
    return {
      'errorClass': error.runtimeType.toString(),
      if (error is SocketException) 'errno': error.osError?.errorCode,
      'family': 'default',
      'explicitProxy': coreProxy
    };
  } finally {
    client.close(force: true);
  }
}

Future<void> runAndroidNetworkAcceptance() async {
  if (!const bool.fromEnvironment('ENTOMA_NETWORK_ACCEPTANCE')) return;
  _record({'phase': 'waiting_for_existing_session'});
  try {
    await _wait(() => globalState.isInit, const Duration(minutes: 10));
    final controller = globalState.appController;
    if (!controller.context.mounted) return;
    final container =
        ProviderScope.containerOf(controller.context, listen: false);
    await _wait(
        () =>
            container.read(initProvider) &&
            container.read(solutionSessionProvider).authenticated &&
            container.read(currentProfileProvider) != null,
        const Duration(minutes: 10));
    final originalVpn = container.read(vpnSettingProvider);
    final originalConfig = container.read(patchClashConfigProvider);
    const node =
        String.fromEnvironment('ENTOMA_NETWORK_NODE', defaultValue: 'test');
    final groups = await clashCore.getProxiesGroups();
    final group = groups.firstWhere((g) =>
        g.type == GroupType.Selector &&
        g.name != 'GLOBAL' &&
        g.all.any((p) => p.name == node));
    controller.updateCurrentSelectedMap(group.name, node);
    _record({
      'phase': 'node_selected',
      'node': node,
      'coreDelayMs': (await clashCore.getDelay(
              'https://www.gstatic.com/generate_204', node))
          .value
    });
    final cases = [
      (TunStack.mixed, false),
      (TunStack.system, false),
      (TunStack.gvisor, false),
      (TunStack.gvisor, true),
      (TunStack.system, true),
      (TunStack.mixed, true)
    ];
    try {
      for (final cell in cases) {
        await _stopAndConfirm();
        container.read(vpnSettingProvider.notifier).updateState(
            (v) => v.copyWith(enable: true, systemProxy: cell.$2, ipv6: false));
        container
            .read(patchClashConfigProvider.notifier)
            .updateState((v) => v.copyWith.tun(stack: cell.$1));
        await Future<void>.delayed(const Duration(seconds: 1));
        for (var cycle = 0; cycle < 3; cycle++) {
          await _stopAndConfirm();
          await _wait(() => !globalState.isStart, const Duration(seconds: 10));
          await Future<void>.delayed(const Duration(milliseconds: 500));
          _record({
            'phase': 'stopped',
            'stack': cell.$1.name,
            'proxy': cell.$2,
            'cycle': cycle,
            'native': await _snapshot()
          });
          try {
            await controller.updateStatus(true);
            await controller.changeProxy(
                groupName: group.name, proxyName: node);
            await Future<void>.delayed(const Duration(milliseconds: 500));
            _record({
              'phase': 'connected',
              'stack': cell.$1.name,
              'proxy': cell.$2,
              'cycle': cycle,
              'native': await _snapshot()
            });
            // A bounded window for the independent adb-shell HTTPS probe.
            // Its results cannot be substituted with this app's own requests.
            await Future<void>.delayed(const Duration(seconds: 25));
            _record({
              'phase': 'probe',
              'stack': cell.$1.name,
              'proxy': cell.$2,
              'cycle': cycle,
              'native': await _snapshot(),
              'default': await _probe(node),
              'coreProxyControl': await _probe(node, coreProxy: true)
            });
          } catch (error) {
            _record({
              'phase': 'start_error',
              'stack': cell.$1.name,
              'proxy': cell.$2,
              'cycle': cycle,
              'errorClass': error.runtimeType.toString()
            });
          }
        }
      }
    } finally {
      await _stopAndConfirm();
      container
          .read(vpnSettingProvider.notifier)
          .updateState((_) => originalVpn);
      container
          .read(patchClashConfigProvider.notifier)
          .updateState((_) => originalConfig);
    }
    _record({'phase': 'complete', 'native': await _snapshot()});
  } catch (error) {
    _record(
        {'phase': 'harness_error', 'errorClass': error.runtimeType.toString()});
  }
}
