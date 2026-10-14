import 'dart:async';

/// Awaited macOS shutdown. The injected actions keep ordering and failure
/// behavior testable without closing the test process or changing OS settings.
class MacOSExitCoordinator {
  MacOSExitCoordinator({
    required this.prepareForExit,
    required this.waitForConfiguration,
    required this.restoreDns,
    required this.restoreProxy,
    required this.shutdown,
    required this.savePreferences,
    required this.exit,
  });

  final Future<void> Function() prepareForExit;
  final Future<void> Function() waitForConfiguration;
  final Future<bool> Function() restoreDns;
  final Future<bool> Function() restoreProxy;
  final Future<void> Function() shutdown;
  final Future<void> Function() savePreferences;
  final Future<void> Function() exit;
  Future<bool>? _flight;
  bool _completed = false;
  bool isClosing = false;

  Future<bool> requestExit() {
    if (_completed) return Future.value(true);
    if (_flight != null) return _flight!;
    isClosing = true;
    // Establish the flight before invoking any injected action: a synchronous
    // failure must not overwrite the cleanup that makes another attempt possible.
    final completion = Completer<bool>();
    _flight = completion.future;
    unawaited(_performExit().then<void>(completion.complete));
    return completion.future;
  }

  Future<bool> _performExit() async {
    try {
      await prepareForExit();
      // A previously failed configuration must not prevent owned cleanup.
      try {
        await waitForConfiguration();
      } catch (_) {}
      bool dnsRestored = false;
      bool proxyRestored = false;
      try {
        dnsRestored = await restoreDns();
      } catch (_) {}
      try {
        proxyRestored = await restoreProxy();
      } catch (_) {}
      if (!dnsRestored || !proxyRestored) return false;
      await shutdown();
      await savePreferences();
      await exit();
      _completed = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      if (!_completed) {
        isClosing = false;
        _flight = null;
      }
    }
  }
}
