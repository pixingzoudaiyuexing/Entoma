import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:proxy/proxy_platform_interface.dart';

enum DesktopProxyPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  failed
}

class DesktopProxyConfiguration {
  final int port;
  final List<String> bypass;
  DesktopProxyConfiguration(this.port, List<String> bypass)
      : bypass = List.unmodifiable(bypass);
}

/// The only desktop system-proxy writer. Requests converge on the latest intent;
/// native calls and rollback never overlap, including after a failed start.
class DesktopProxyCoordinator extends ChangeNotifier {
  DesktopProxyCoordinator({
    required this.configuration,
    required this.coreRunning,
    required this.hasOtherCoreUsers,
    this.waitForCoreIdle,
    required this.startCore,
    required this.stopCore,
    required this.waitForListener,
    required this.apply,
    required this.restore,
    required this.readback,
  });

  final DesktopProxyConfiguration Function() configuration;
  final bool Function() coreRunning;
  final bool Function() hasOtherCoreUsers;
  final Future<void> Function()? waitForCoreIdle;
  final Future<void> Function() startCore;
  final Future<void> Function() stopCore;
  final Future<void> Function(int port) waitForListener;
  final Future<bool?> Function(int port, List<String> bypass) apply;
  final Future<bool?> Function() restore;
  final Future<ProxyStatus> Function(int port, List<String> bypass) readback;
  DesktopProxyPhase phase = DesktopProxyPhase.disconnected;
  Object? failure;
  bool desired = false;
  bool _autoStarted = false;
  bool _sealed = false;
  bool _disposed = false;
  bool _needsRestore = false;
  int _revision = 0;
  Future<void>? _flight;
  Future<void>? _checking;

  bool get busy =>
      phase == DesktopProxyPhase.connecting ||
      phase == DesktopProxyPhase.disconnecting;

  void _publish(DesktopProxyPhase next, [Object? error]) {
    phase = next;
    failure = error;
    if (!_disposed) notifyListeners();
  }

  Future<void> request(bool enabled) {
    if (_sealed && enabled) return Future.error(StateError('应用正在退出'));
    desired = enabled;
    _revision++;
    return _drain();
  }

  Future<void> _drain() {
    if (_flight != null) return _flight!;
    final done = Completer<void>();
    _flight = done.future;
    unawaited(() async {
      try {
        while (true) {
          final revision = _revision;
          try {
            if (desired && !_sealed) {
              await _connect();
            } else {
              await _disconnect();
            }
          } catch (error) {
            _publish(DesktopProxyPhase.failed, error);
          }
          if (revision == _revision) break;
        }
      } finally {
        _flight = null;
        done.complete();
      }
    }());
    return done.future;
  }

  Future<void> _connect() async {
    _publish(DesktopProxyPhase.connecting);
    try {
      var config = configuration();
      // Fail early for unavailable native backends (including unsigned Helper).
      final availability = await readback(config.port, config.bypass);
      _needsRestore = _needsRestore ||
          availability.owned ||
          availability.restorationPending;
      if (!availability.available) throw StateError('系统代理服务不可用');
      // An independent/manual stop may already be waiting for its native
      // acknowledgement. Do not reuse that listener before the stop settles.
      await waitForCoreIdle?.call();
      if (!desired || _sealed) return;
      if (!coreRunning()) {
        _autoStarted = true;
        await startCore();
      }
      if (!desired || _sealed) return;
      if (!coreRunning()) throw StateError('代理核心尚未启动');
      config = configuration();
      await waitForListener(config.port);
      if (!desired || _sealed) return;
      _needsRestore = true;
      if (await apply(config.port, config.bypass) != true) {
        throw StateError('系统代理设置未完成');
      }
      final actual = await readback(config.port, config.bypass);
      if (!desired || _sealed) return;
      if (!actual.available ||
          !actual.matches ||
          actual.restorationPending ||
          !coreRunning()) {
        throw StateError('系统代理状态核验失败');
      }
      _publish(DesktopProxyPhase.connected);
    } catch (error) {
      // A failed reply can still follow a partial native write. Keep the core
      // alive unless authoritative restoration succeeded.
      try {
        if (_needsRestore) {
          await _restoreAndReleaseCore();
        } else {
          await _releaseCore();
        }
      } catch (_) {
        throw StateError('系统代理尚未恢复，请重试关闭；核心已保留');
      }
      rethrow;
    }
  }

  Future<void> _restoreAndReleaseCore() async {
    if (await restore() != true) throw StateError('系统代理尚未恢复');
    if (_needsRestore || _autoStarted) {
      final config = configuration();
      final actual = await readback(config.port, config.bypass);
      if (!actual.available || actual.owned || actual.restorationPending) {
        throw StateError('系统代理恢复状态尚未确认');
      }
      if (actual.usesListener) {
        throw StateError('其他系统代理设置仍在使用此核心，请调整后重试关闭');
      }
    }
    _needsRestore = false;
    await _releaseCore();
  }

  Future<void> _releaseCore() async {
    // A later DNS/core/preferences step may still abort normal exit. Retain
    // ownership until that transaction really exits or resumes ordinary use.
    if (_sealed) return;
    if (_autoStarted && !_sealed && coreRunning() && !hasOtherCoreUsers()) {
      await stopCore();
    }
    _autoStarted = false;
  }

  Future<void> _disconnect() async {
    _publish(DesktopProxyPhase.disconnecting);
    await _restoreAndReleaseCore();
    _publish(DesktopProxyPhase.disconnected);
  }

  /// No automatic re-apply after a crash or external OS change. A user retry is
  /// required. Observations join the same mutation queue through request().
  Future<void> verify() => _checking ??= _verify().whenComplete(() {
        _checking = null;
      });

  Future<void> _verify() async {
    if (_flight != null || phase != DesktopProxyPhase.connected) return;
    final revision = _revision;
    final config = configuration();
    try {
      final actual = await readback(config.port, config.bypass);
      if (revision != _revision || _flight != null || _sealed) return;
      if (coreRunning() &&
          actual.available &&
          actual.matches &&
          !actual.restorationPending) return;
    } catch (_) {
      if (revision != _revision || _flight != null || _sealed) return;
    }
    desired = false;
    _revision++;
    await _drain();
    if (revision + 1 == _revision) {
      _publish(DesktopProxyPhase.failed, StateError('核心或系统代理状态已改变，请检查后重试'));
    }
  }

  Future<bool> prepareForExit() async {
    seal();
    await request(false);
    return phase == DesktopProxyPhase.disconnected;
  }

  void seal() {
    _sealed = true;
    desired = false;
  }

  Future<void> waitForIdle() async => await _flight;

  void cancelExit() => _sealed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A successful TCP connect alone could be an unrelated occupied port. Verify
/// the mixed listener's SOCKS greeting, in addition to the core start result.
Future<void> waitForMixedProxy(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 400));
      socket.add([5, 1, 0]);
      final bytes = await socket
          .expand((chunk) => chunk)
          .take(2)
          .toList()
          .timeout(const Duration(milliseconds: 400));
      if (listEquals(bytes, [5, 0])) return;
    } catch (_) {
      // Poll an observed condition under a deadline, never infer readiness from
      // a fixed startup delay.
    } finally {
      socket?.destroy();
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  throw StateError('本地代理监听未就绪，请检查端口和配置');
}
