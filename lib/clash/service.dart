import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/clash/interface.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/core_launch.dart';
import 'package:fl_clash/common/core_launch_deadline.dart';
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
  CoreLaunchDeadline? launchDeadline;
  Timer? markerPoll;
  File? readyMarker;
  bool readingMarker = false;
  bool authorizationCancelled = false;
  void cancelTimers() {
    launchDeadline?.cancel();
    markerPoll?.cancel();
  }

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
  final _launchEpoch = CoreLaunchEpoch();
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
                  commonPrint
                      .log('Core IPC rejected an unauthenticated connection');
                  socket.destroy();
                  return;
                }
                owner = session;
                proofTimeout.cancel();
                session.cancelTimers();
                unawaited(_removeMarker(session));
                session.socket.complete(socket);
                system.elevatedCoreActive = session.elevated;
                commonPrint.log('Core IPC authenticated');
                return;
              }
              if (owner != _active || owner!.closed) {
                socket.destroy();
                return;
              }
              handleResult(ActionResult.fromJson(value));
            } catch (error) {
              commonPrint.log('Core IPC frame rejected: ${error.runtimeType}');
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
    final epoch = _launchEpoch.begin();
    await _shutdown(invalidateLaunch: false);
    if (_destroyed || !_launchEpoch.isCurrent(epoch)) return;
    final server = await serverCompleter.future;
    if (_destroyed || !_launchEpoch.isCurrent(epoch)) return;
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
    if (_destroyed || !_launchEpoch.isCurrent(epoch)) return;
    final session = _CoreSession(system.elevatedCoreRequested);
    _active = session;
    final endpoint =
        Platform.isWindows ? '${server.port}' : server.address.address;
    final argument = '$endpoint|${session.secret}';
    session.launchDeadline = CoreLaunchDeadline((phase) {
      if (_active != session || session.socket.isCompleted) return;
      session.cancelTimers();
      session.socket.completeError(StateError(
          phase == CoreLaunchPhase.authorization
              ? 'Core authorization or launch timed out'
              : 'Core authentication timed out after executable launch'));
      session.process?.kill();
      system.elevatedCoreRequested = false;
      unawaited(_removeMarker(session));
      _markDisconnected();
      _failPending();
    });
    try {
      if (!(session.elevated && Platform.isMacOS)) {
        session.launchDeadline!.executableLaunched();
      }
      if (session.elevated && Platform.isWindows) {
        if (windows?.runas(appPath.corePath, argument) != true) {
          throw StateError('Core elevation was cancelled');
        }
      } else if (session.elevated && Platform.isMacOS) {
        final markerId = List.generate(16, (_) => Random.secure().nextInt(256))
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join();
        session.readyMarker =
            File('${_socketDirectory!.path}/launch-$markerId.ready');
        session.launchDeadline!.waitingForAuthorization();
        session.markerPoll =
            Timer.periodic(const Duration(milliseconds: 100), (_) {
          unawaited(_checkLaunchMarker(session));
        });
        commonPrint.log('Core launch waiting for administrator authorization');
        final launched = await Process.start('osascript', [
          '-e',
          elevatedMacCommand(appPath.corePath, argument,
              readyPath: session.readyMarker!.path),
        ]);
        if (!_launchEpoch.acceptHandle(epoch, () {
          launched.kill();
        }, ownerCurrent: _active == session && !session.closed)) {
          unawaited(launched.stdout.drain<void>());
          unawaited(launched.stderr.drain<void>());
          return;
        }
        session.process = launched;
      } else {
        final launched = await Process.start(appPath.corePath, [argument]);
        if (!_launchEpoch.acceptHandle(epoch, () {
          launched.kill();
        }, ownerCurrent: _active == session && !session.closed)) {
          unawaited(launched.stdout.drain<void>());
          unawaited(launched.stderr.drain<void>());
          return;
        }
        session.process = launched;
      }
      commonPrint.log(session.readyMarker == null
          ? 'Core executable launched'
          : 'Core authorization process launched');
      session.process?.stdout.drain<void>();
      session.process?.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (session.readyMarker != null && line.contains('(-128)')) {
          session.authorizationCancelled = true;
        }
        if (line.startsWith('panic:'))
          commonPrint.log('Core stopped after a runtime panic');
        if (line.startsWith('core.') || line.startsWith('main.')) {
          commonPrint.log(line.split('(').first);
        }
      });
      session.process?.exitCode.then((code) {
        if (_active != session || session.closed) return;
        commonPrint.log('Core process exited: $code');
        session.cancelTimers();
        if (!session.socket.isCompleted)
          session.socket.completeError(StateError(session.authorizationCancelled
              ? 'Core authorization was cancelled'
              : 'Core exited before authentication'));
        unawaited(_removeMarker(session));
        system.elevatedCoreRequested = false;
        _markDisconnected();
        _failPending();
      });
    } catch (error) {
      commonPrint.log('Core launch failed: ${error.runtimeType}');
      session.cancelTimers();
      if (!session.socket.isCompleted)
        session.socket.completeError(StateError('Core could not start'));
      system.elevatedCoreRequested = false;
      unawaited(_removeMarker(session));
      if (_active == session) _markDisconnected();
      rethrow;
    }
  }

  Future<void> _removeMarker(_CoreSession session) async {
    final marker = session.readyMarker;
    if (marker == null) return;
    try {
      if (await marker.exists()) await marker.delete();
    } on FileSystemException {
      // Retain the path for the shutdown retry; never remove other temp files.
      return;
    }
  }

  Future<void> _checkLaunchMarker(_CoreSession session) async {
    if (_active != session ||
        session.closed ||
        session.socket.isCompleted ||
        session.readingMarker) return;
    session.readingMarker = true;
    try {
      final marker = session.readyMarker!;
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file) return;
      final length = await marker.length();
      if (length == 0 || length > 20) return;
      final pid = await marker.readAsString();
      if (!RegExp(r'^[1-9][0-9]*$').hasMatch(pid)) return;
      if (_active != session || session.closed || session.socket.isCompleted)
        return;
      session.markerPoll?.cancel();
      session.launchDeadline!.executableLaunched();
      commonPrint.log('Core elevated executable launch observed');
      await _removeMarker(session);
    } on FileSystemException {
      // Marker is not ready yet, or this session was cancelled during the read.
    } finally {
      session.readingMarker = false;
    }
  }

  Future<void> cancelPendingLaunch() async {
    _launchEpoch.cancel();
    final session = _active;
    if (session != null && !session.socket.isCompleted) await shutdown();
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
  Future<bool> shutdown() => _shutdown(invalidateLaunch: true);

  Future<bool> _shutdown({required bool invalidateLaunch}) async {
    if (invalidateLaunch) _launchEpoch.cancel();
    final session = _active;
    _active = null;
    system.elevatedCoreActive = false;
    if (session == null) return true;
    session.closed = true;
    session.cancelTimers();
    if (session.socket.isCompleted) {
      try {
        (await session.socket.future).destroy();
      } catch (_) {}
    } else {
      session.socket.completeError(StateError('Core stopped'));
    }
    session.process?.kill();
    await _removeMarker(session);
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
