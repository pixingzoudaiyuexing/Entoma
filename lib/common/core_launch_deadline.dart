import 'dart:async';

enum CoreLaunchPhase { authorization, authentication }

/// Retiring a launch also retires async work that has not produced a process
/// handle yet. A handle delivered after cancellation must be killed by its owner.
class CoreLaunchEpoch {
  int _generation = 0;
  int begin() => ++_generation;
  void cancel() {
    ++_generation;
  }

  bool isCurrent(int expected) => expected == _generation;
  bool acceptHandle(int expected, void Function() kill,
      {bool ownerCurrent = true}) {
    if (ownerCurrent && isCurrent(expected)) return true;
    kill();
    return false;
  }
}

/// Authorization time is not an IPC handshake failure. Each launch owns its
/// deadline; cancel it before retiring that launch's session.
class CoreLaunchDeadline {
  final void Function(CoreLaunchPhase phase) onTimeout;
  final Duration authorizationLimit;
  final Duration authenticationLimit;
  Timer? _timer;
  bool _finished = false;
  bool _launched = false;

  CoreLaunchDeadline(
    this.onTimeout, {
    this.authorizationLimit = const Duration(minutes: 5),
    this.authenticationLimit = const Duration(seconds: 60),
  });

  void waitingForAuthorization() {
    if (_finished || _launched) return;
    _arm(CoreLaunchPhase.authorization, authorizationLimit);
  }

  void executableLaunched() {
    if (_finished || _launched) return;
    _launched = true;
    _arm(CoreLaunchPhase.authentication, authenticationLimit);
  }

  void _arm(CoreLaunchPhase phase, Duration limit) {
    _timer?.cancel();
    _timer = Timer(limit, () {
      if (_finished) return;
      _finished = true;
      onTimeout(phase);
    });
  }

  void cancel() {
    _finished = true;
    _timer?.cancel();
  }
}
