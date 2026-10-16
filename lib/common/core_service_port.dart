import 'dart:async';
import 'dart:isolate';

/// Keeps the service engine's ports alive while its UI client is replaced.
/// Each command reply belongs to the client that submitted that command.
class CoreServicePort {
  CoreServicePort({
    required FutureOr<Object?> Function(dynamic) handleAction,
    void Function(SendPort)? attachMessagePort,
    Future<void> Function()? waitForReady,
  })  : _handleAction = handleAction,
        _waitForReady = waitForReady {
    _commands.listen(_handleCommand);
    _messages.listen((message) {
      if (!_closed) _client?.send(message);
    });
    try {
      attachMessagePort?.call(messagePort);
    } catch (_) {
      close();
      rethrow;
    }
  }

  final FutureOr<Object?> Function(dynamic) _handleAction;
  final Future<void> Function()? _waitForReady;
  final ReceivePort _commands = ReceivePort();
  final ReceivePort _messages = ReceivePort();
  SendPort? _client;
  bool _closed = false;

  SendPort get sendPort => _commands.sendPort;
  SendPort get messagePort => _messages.sendPort;

  void attach(SendPort client) {
    if (_closed) throw StateError('Core service ports are closed');
    _client = client;
    client.send(sendPort);
  }

  Future<void> _handleCommand(dynamic message) async {
    if (_closed) return;
    if (message is SendPort) {
      attach(message);
      return;
    }
    final requestingClient = _client;
    await _waitForReady?.call();
    if (_closed) return;
    // Preserve independent core requests: a node delay request must not hold
    // unrelated status requests behind its timeout.
    final result = await _handleAction(message);
    // Do not resolve an old UI's callback in its replacement UI, even when
    // both UI instances happen to reuse the same callback identifier.
    if (!_closed) requestingClient?.send(result);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client = null;
    _commands.close();
    _messages.close();
  }
}
