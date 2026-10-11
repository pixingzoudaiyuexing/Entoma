import 'dart:async';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  Future<void> _changes = Future.value();
  _updateProxy(ProxyState proxyState) async {
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    if (isStart && systemProxy) {
      final result = await proxy?.startProxy(port, proxyState.bassDomain);
      if (result == false)
        globalState.showNotifier('无法设置系统代理。原有设置已保留，请检查系统权限。');
    } else {
      final result = await proxy?.stopProxy();
      if (result == false) globalState.showNotifier('系统代理尚未恢复，请检查系统设置。');
    }
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      proxyStateProvider,
      (prev, next) {
        if (prev != next) {
          _changes = _changes.catchError((_) {}).then((_) async {
            if (mounted) await _updateProxy(ref.read(proxyStateProvider));
          });
        }
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
