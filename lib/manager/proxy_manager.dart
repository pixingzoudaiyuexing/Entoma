import 'dart:async';
import 'dart:io';
import 'package:fl_clash/common/desktop_proxy.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  Future<void> _changes = Future.value();
  Timer? _verification;
  ProxyState? _lastDesktopState;
  bool get _oneClick => Platform.isMacOS || Platform.isWindows;

  void _syncDesktop(ProxyState value) {
    final controller = globalState.appController;
    if (controller.isClosing) return;
    final previous = _lastDesktopState;
    _lastDesktopState = value;
    if (!ref.read(initProvider)) return;
    final coordinator = controller.desktopProxy;
    if (previous != null &&
        coordinator.desired &&
        coordinator.phase == DesktopProxyPhase.connected &&
        (previous.port != value.port ||
            !listEquals(previous.bassDomain, value.bassDomain))) {
      // A configuration observation can update an existing connection, never
      // turn a saved mode preference into a new connection or failed retry.
      unawaited(coordinator.request(true));
    } else {
      unawaited(coordinator.verify());
    }
  }

  _updateProxy(ProxyState proxyState) async {
    if (proxy == null) return;
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    if (isStart &&
        systemProxy &&
        !(globalState.isInit && globalState.appController.isClosing)) {
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
          if (_oneClick) {
            _syncDesktop(next);
            return;
          }
          _changes = _changes.catchError((_) {}).then((_) async {
            if (mounted) await _updateProxy(ref.read(proxyStateProvider));
          });
        }
      },
      fireImmediately: true,
    );
    if (_oneClick) {
      ref.listenManual(initProvider, (previous, ready) {
        if (ready) {
          _lastDesktopState = null;
          _syncDesktop(ref.read(proxyStateProvider));
        }
      });
      _verification = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) unawaited(globalState.appController.desktopProxy.verify());
      });
    }
  }

  @override
  void dispose() {
    _verification?.cancel();
    if (_oneClick) {
      // Normal desktop exit owns and awaits restoration. Do not create an
      // unobserved second native write queue during widget teardown.
      super.dispose();
      return;
    }
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
