import 'dart:async';

/// Owns true exit until native VPN cleanup, core shutdown and engine destruction
/// have acknowledged completion. Minimizing does not enter this transaction.
class AndroidExitCoordinator {
  AndroidExitCoordinator({
    required this.prepareForExit,
    required this.waitForOperations,
    required this.savePreferences,
    required this.stopVpn,
    required this.shutdownCore,
    required this.destroyEngine,
    required this.exit,
    required this.cancelExit,
  });

  final Future<void> Function() prepareForExit;
  final Future<void> Function() waitForOperations;
  final Future<void> Function() savePreferences;
  final Future<bool> Function() stopVpn;
  final Future<bool> Function() shutdownCore;
  final Future<bool> Function() destroyEngine;
  final Future<void> Function() exit;
  final Future<void> Function() cancelExit;

  Future<bool>? _flight;
  bool _completed = false;
  bool _engineDestroyed = false;
  bool _shutdownStarted = false;
  bool isClosing = false;

  Future<bool> requestExit() {
    if (_completed) return Future.value(true);
    if (_flight != null) return _flight!;
    isClosing = true;
    final completion = Completer<bool>();
    _flight = completion.future;
    unawaited(_performExit().then<void>(completion.complete));
    return completion.future;
  }

  Future<bool> _performExit() async {
    try {
      if (!_engineDestroyed) {
        await prepareForExit();
        // An admitted profile operation owns its commit/rollback. Its failure
        // does not waive the separate obligation to stop the native VPN.
        try {
          await waitForOperations();
        } catch (_) {}
        await savePreferences();
        if (!await stopVpn()) return false;
        // A timed-out core request may still be executing. Once dispatched,
        // keep admission closed until teardown is positively reconciled.
        _shutdownStarted = true;
        if (!await shutdownCore()) return false;
        if (!await destroyEngine()) return false;
        _engineDestroyed = true;
      }
      await exit();
      _completed = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      if (!_completed) {
        if (!_engineDestroyed && !_shutdownStarted) {
          try {
            // Native code only reopens admission once a pending stop settles.
            await cancelExit();
            isClosing = false;
          } catch (_) {
            // Keep admission closed when safe recovery is not acknowledged.
          }
        }
        // The engine may already be gone if Activity finishing failed. Retry
        // that last action without reopening admission or touching a dead port.
        _flight = null;
      }
    }
  }
}
