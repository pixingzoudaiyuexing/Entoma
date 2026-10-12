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
    if (proxy == null) return;
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    if (isStart && systemProxy) {
      try {
        if (await proxy!.startProxy(port, proxyState.bassDomain) == true) {
          return;
        }
      } catch (_) {
        // The native side may still own a partially applied snapshot.
      }
      bool restored = false;
      try {
        restored = await proxy!.stopProxy() == true;
      } catch (_) {}
      if (!mounted) return;
      globalState.showNotifier(
          restored ? '无法设置系统代理，请检查系统权限后重试。' : '系统代理设置失败且尚未恢复，请检查系统设置后重试关闭。');
    } else {
      try {
        if (await proxy!.stopProxy() == true) return;
      } catch (_) {}
      if (mounted) globalState.showNotifier('系统代理尚未恢复，请检查系统设置后重试关闭。');
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
  void dispose() {
    _changes = _changes.catchError((_) {}).then((_) async {
      try {
        await proxy?.stopProxy();
      } catch (_) {}
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
