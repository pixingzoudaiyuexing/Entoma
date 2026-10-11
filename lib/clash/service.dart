import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/clash/interface.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/core_launch.dart';
import 'package:fl_clash/models/core.dart';
import 'package:fl_clash/state.dart';
import 'package:crypto/crypto.dart';

class _CoreSession {
  final String secret = List.generate(
    32,
    (_) => Random.secure().nextInt(256),
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  final Completer<Socket> socket = Completer();
  final bool elevated;
  Process? process;
  Timer? authenticationTimeout;
  bool closed = false;
  _CoreSession(this.elevated) {
    socket.future.ignore();
  }
}

class ClashService extends ClashHandlerInterface {
  static ClashService? _instance;
  final Completer<ServerSocket> serverCompleter = Completer();
  Directory? _socketDirectory;
  String? _socketPath;
  _CoreSession? _active;
  Future<void>? _restarting;
  bool _destroyed = false;
  bool get hasSession => _active != null && !_active!.closed;

  factory ClashService() => _instance ??= ClashService._internal();
  ClashService._internal() {
    serverCompleter.future.ignore();
    _initServer();
    reStart().catchError((_) {});
  }

  Future<void> _initServer() async {
    try {
      if (!Platform.isWindows) {
        final temporaryRoot =
            Platform.isMacOS ? Directory('/private/tmp') : Directory.systemTemp;
        _socketDirectory = await temporaryRoot.createTemp('entoma-');
        final mode = await Process.run('chmod', [
          '700',
          _socketDirectory!.path,
        ]);
        if (mode.exitCode != 0)
          throw StateError('Cannot protect core IPC directory');
        _socketPath = '${_socketDirectory!.path}/core.sock';
      }
      final address = Platform.isWindows
          ? InternetAddress.loopbackIPv4
          : InternetAddress(_socketPath!, type: InternetAddressType.unix);
      final server = await ServerSocket.bind(address, 0, shared: false);
      if (_socketPath != null) {
        final mode = await Process.run('chmod', ['600', _socketPath!]);
        if (mode.exitCode != 0) {
          await server.close();
          throw StateError('Cannot protect core IPC');
        }
      }
      serverCompleter.complete(server);
      await for (final socket in server) {
        _accept(socket);
      }
    } catch (error) {
      if (!serverCompleter.isCompleted) serverCompleter.completeError(error);
    }
  }

  void _accept(Socket socket) {
    _CoreSession? owner;
    final proofTimeout = Timer(const Duration(seconds: 5), socket.destroy);
    var frameBytes = 0;
    socket
        .cast<List<int>>()
        .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (bytes, sink) {
          for (final byte in bytes) {
            frameBytes = byte == 10 ? 0 : frameBytes + 1;
            if (frameBytes > (owner == null ? 4096 : 16 * 1024 * 1024)) {
              socket.destroy();
              sink.close();
              return;
            }
          }
          sink.add(bytes);
        }))
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (data) {
            try {
              final value = json.decode(data);
              if (owner == null) {
                final session = _active;
                if (session == null ||
                    session.closed ||
                    session.socket.isCompleted ||
                    value is! Map ||
                    value['auth'] != session.secret) {
                  socket.destroy();
                  return;
                }
                owner = session;
                proofTimeout.cancel();
                session.authenticationTimeout?.cancel();
                session.socket.complete(socket);
                system.elevatedCoreActive = session.elevated;
                return;
              }
              if (owner != _active || owner!.closed) {
                socket.destroy();
                return;
              }
              handleResult(ActionResult.fromJson(value));
            } catch (_) {
              socket.destroy();
            }
          },
          onDone: () {
            proofTimeout.cancel();
            if (owner == _active && owner != null) {
              _markDisconnected();
              _failPending();
            }
          },
          onError: (_) {
            proofTimeout.cancel();
            socket.destroy();
          },
        );
  }

  void _markDisconnected() {
    system.elevatedCoreActive = false;
    _active?.closed = true;
    _active = null;
    if (!globalState.isInit) return;
    globalState.appController.handleCoreDisconnected();
    globalState.showNotifier('代理核心已断开，系统代理将恢复。请重试连接。');
  }

  void _failPending() {
    for (final completer in callbackCompleterMap.values) {
      if (!completer.isCompleted)
        completer.completeError(StateError('Core disconnected'));
    }
    callbackCompleterMap.clear();
  }

  @override
  Future<void> reStart() => _restarting ??= _restart().whenComplete(() {
        _restarting = null;
      });

  Future<void> _restart() async {
    await shutdown();
    if (_destroyed) return;
    final server = await serverCompleter.future;
    if (system.elevatedCoreRequested) {
      final expectedHash = globalState.coreSHA256;
      if (expectedHash == null ||
          expectedHash.isEmpty ||
          (await sha256.bind(File(appPath.corePath).openRead()).first)
                  .toString() !=
              expectedHash) {
        system.elevatedCoreRequested = false;
        throw StateError('Core integrity could not be verified');
      }
    }
    final session = _CoreSession(system.elevatedCoreRequested);
    _active = session;
    final endpoint =
        Platform.isWindows ? '${server.port}' : server.address.address;
    final argument = '$endpoint|${session.secret}';
    session.authenticationTimeout = Timer(const Duration(seconds: 60), () {
      if (_active != session || session.socket.isCompleted) return;
      session.socket.completeError(StateError('Core authentication timed out'));
      session.process?.kill();
      system.elevatedCoreRequested = false;
    });
    try {
      if (session.elevated && Platform.isWindows) {
        if (windows?.runas(appPath.corePath, argument) != true) {
          throw StateError('Core elevation was cancelled');
        }
      } else if (session.elevated && Platform.isMacOS) {
        session.process = await Process.start('osascript', [
          '-e',
          elevatedMacCommand(appPath.corePath, argument),
        ]);
      } else {
        session.process = await Process.start(appPath.corePath, [argument]);
      }
      session.process?.stdout.drain<void>();
      session.process?.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('panic:'))
          commonPrint.log('Core stopped after a runtime panic');
        if (line.startsWith('core.') || line.startsWith('main.')) {
          commonPrint.log(line.split('(').first);
        }
      });
      session.process?.exitCode.then((_) {
        if (_active != session || session.closed) return;
        session.authenticationTimeout?.cancel();
        if (!session.socket.isCompleted)
          session.socket.completeError(StateError('Core exited'));
        system.elevatedCoreRequested = false;
        _markDisconnected();
        _failPending();
      });
    } catch (_) {
      session.authenticationTimeout?.cancel();
      if (!session.socket.isCompleted)
        session.socket.completeError(StateError('Core could not start'));
      system.elevatedCoreRequested = false;
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(String message) async {
    final session = _active;
    if (session == null || session.closed)
      throw StateError('Core is unavailable');
    final socket = await session.socket.future;
    if (_active != session || session.closed) throw StateError('Core changed');
    socket.writeln(message);
  }

  @override
  Future<bool> shutdown() async {
    final session = _active;
    _active = null;
    system.elevatedCoreActive = false;
    if (session == null) return true;
    session.closed = true;
    session.authenticationTimeout?.cancel();
    if (session.socket.isCompleted) {
      try {
        (await session.socket.future).destroy();
      } catch (_) {}
    } else {
      session.socket.completeError(StateError('Core stopped'));
    }
    session.process?.kill();
    _failPending();
    return true;
  }

  @override
  Future<bool> destroy() async {
    _destroyed = true;
    await shutdown();
    await (await serverCompleter.future).close();
    if (_socketPath != null) {
      final socket = File(_socketPath!);
      if (await socket.exists()) await socket.delete();
    }
    if (_socketDirectory != null && await _socketDirectory!.exists()) {
      await _socketDirectory!.delete();
    }
    return true;
  }

  @override
  Future<bool> preload() async {
    await serverCompleter.future;
    return true;
  }
}

final clashService = system.isDesktop ? ClashService() : null;
