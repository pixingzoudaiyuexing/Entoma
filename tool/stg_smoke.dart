// Credentials enter through stdin and are never written to disk or stdout.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/configuration.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class SafeProbeClient extends http.BaseClient {
  final http.Client inner;
  SafeProbeClient({int? loopbackProxyPort})
      : inner = IOClient(HttpClient()
          ..connectionTimeout = const Duration(seconds: 8)
          ..findProxy = (uri) => loopbackProxyPort == null
              ? 'DIRECT'
              : 'PROXY 127.0.0.1:$loopbackProxyPort');
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final resource = request.url.path.startsWith('/api/v1/')
        ? request.url.path
        : 'subscription-body';
    stderr.writeln('Sending $resource');
    try {
      final response = await inner.send(request);
      stderr.writeln('Headers $resource ${response.statusCode}');
      return response;
    } catch (error) {
      stderr.writeln('Transport $resource ${error.runtimeType}');
      rethrow;
    }
  }

  @override
  void close() {
    inner.close();
    stderr.writeln('HTTP client closed');
  }
}

Future<void> main(List<String> arguments) async {
  final input = object(jsonDecode(await stdin.transform(utf8.decoder).join()));
  final proxyPort = input['loopbackProxyPort'];
  if (proxyPort != null &&
      (proxyPort is! int || proxyPort < 1 || proxyPort > 65535)) {
    throw ArgumentError('Invalid loopback proxy port');
  }
  final api = SolutionApi(
      baseUrl: input['origin'] as String? ?? solutionOrigin,
      client: SafeProbeClient(loopbackProxyPort: proxyPort as int?));
  Directory? temporary;
  ServerSocket? server;
  Socket? coreSocket;
  Process? core;
  HttpClient? proxy;
  final evidence = <String, Object?>{};
  evidence['apiTransport'] =
      proxyPort == null ? 'direct' : 'existing-loopback-proxy';
  try {
    stderr.writeln('Checking login');
    final login =
        object(await api.call('/api/v1/auth/login', method: 'POST', body: {
      'email': string(input['email']),
      'password': string(input['password']),
    }));
    final token = string(login['accessToken']);
    evidence['login'] = true;
    final me = object(await api.call('/api/v1/me', token: token));
    evidence['accountActive'] = me['status'] == 'active';
    for (final resource in [
      'wallet',
      'subscription/overview',
      'products',
      'orders',
      'billing/methods',
      'tickets',
      'referrals'
    ]) {
      try {
        stderr.writeln('Checking $resource');
        final data = await api.call('/api/v1/$resource', token: token);
        evidence[resource] = {
          'ok': true,
          if (data is List) 'count': data.length,
          if (resource == 'products')
            'count': objects(object(data)['products']).length,
          if (resource == 'wallet')
            'balanceZero': integer(object(data)['balanceMinor']) == 0,
        };
      } on SolutionError catch (error) {
        evidence[resource] = {'ok': false, 'code': error.code};
      }
    }
    final access = object(await api.call('/api/v1/subscription', token: token));
    if (access['eligible'] != true)
      throw const SolutionError('SUBSCRIPTION_ACCESS_UNAVAILABLE');
    final bytes = await api.download(string(access['accessUrl']));
    final prepared = prepareSubscription(utf8.decode(bytes));
    final config = object(jsonDecode(prepared));
    evidence['subscription'] = {
      'bytes': bytes.length,
      'nodes': objects(config['proxies']).length,
      'preparedSha256': sha256.convert(utf8.encode(prepared)).toString()
    };

    if (arguments.isEmpty) {
      stdout.writeln(jsonEncode(evidence));
      return;
    }
    temporary = await Directory(
            Platform.isMacOS ? '/private/tmp' : Directory.systemTemp.path)
        .createTemp('entoma-smoke-');
    if (!Platform.isWindows)
      await Process.run('chmod', ['700', temporary.path]);
    final home = await Directory(path.join(temporary.path, 'home')).create();
    for (final name in [
      'GeoIP.dat',
      'GeoSite.dat',
      'geoip.metadb',
      'ASN.mmdb'
    ]) {
      await File(path.join('assets', 'data', name))
          .copy(path.join(home.path, name));
    }
    final socketPath = path.join(temporary.path, 'core.sock');
    server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    await Process.run('chmod', ['600', socketPath]);
    final secret = List.generate(32, (_) => Random.secure().nextInt(256))
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    final authenticated = Completer<Socket>();
    final pending = <String, Completer<dynamic>>{};
    server.listen((socket) {
      var trusted = false;
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final message = object(jsonDecode(line));
        if (!trusted) {
          if (message['auth'] != secret) {
            socket.destroy();
            return;
          }
          trusted = true;
          authenticated.complete(socket);
          return;
        }
        pending.remove(message['id'])?.complete(message['data']);
      });
    });
    core = await Process.start(
        path.absolute(arguments.first), ['$socketPath|$secret']);
    core.stdout.drain<void>();
    core.stderr.drain<void>();
    coreSocket =
        await authenticated.future.timeout(const Duration(seconds: 10));
    var serial = 0;
    Future<dynamic> invoke(String method, dynamic data) {
      final id = '${serial++}';
      final completer = Completer<dynamic>();
      pending[id] = completer;
      coreSocket!
          .writeln(jsonEncode({'id': id, 'method': method, 'data': data}));
      return completer.future.timeout(const Duration(seconds: 25));
    }

    evidence['nativeCoreAuthenticated'] = true;
    if (await invoke(
            'initClash', jsonEncode({'home-dir': home.path, 'version': 15})) !=
        true) throw StateError('core init failed');
    if (await invoke('validateConfig', prepared) != '')
      throw StateError('core validation failed');
    evidence['nativeCoreConfigValidation'] = true;
    final reservation =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reservation.port;
    await reservation.close();
    config['mixed-port'] = port;
    config['log-level'] = 'silent';
    final mainGroup = objects(config['proxy-groups'])
        .firstWhere((g) => g['type'] == 'select');
    final firstNode = string(objects(config['proxies']).first['name']);
    final params = {
      'config': config,
      'selected-map': {string(mainGroup['name']): firstNode},
      'test-url': 'https://www.gstatic.com/generate_204'
    };
    if (await invoke('setupConfig', jsonEncode(params)) != '')
      throw StateError('core setup failed');
    if (await invoke('startListener', '') != true)
      throw StateError('core listener failed');
    evidence['nativeCoreStarted'] = true;
    final selection = await invoke('changeProxy',
        jsonEncode({'group-name': mainGroup['name'], 'proxy-name': firstNode}));
    evidence['nodeSelected'] = selection == '';
    final delay = await invoke(
        'asyncTestDelay',
        jsonEncode({
          'proxy-name': firstNode,
          'test-url': 'https://www.gstatic.com/generate_204',
          'timeout': 8000
        }));
    try {
      evidence['latencyMeasured'] =
          (object(jsonDecode(delay as String))['value'] as int) > 0;
    } catch (_) {
      evidence['latencyMeasured'] = false;
    }
    proxy = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = const Duration(seconds: 10);
    Future<bool> transfer() async {
      final request = await proxy!
          .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
          .timeout(const Duration(seconds: 20));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      return response.statusCode == 200 &&
          body.contains('h=www.cloudflare.com');
    }

    evidence['nativeCoreHttpsForwarding'] = await transfer();
    final totals =
        object(jsonDecode(await invoke('getTotalTraffic', '') as String));
    evidence['nativeCoreTrafficPositive'] =
        integer(totals['up']) > 0 && integer(totals['down']) > 0;
    evidence['malformedUpdateRejected'] =
        (await invoke('setupConfig', '{') as String).isNotEmpty;
    evidence['forwardingSurvivesMalformedUpdate'] = await transfer();
    proxy.close(force: true);
    proxy = null;
    await invoke('closeConnections', '');
    evidence['nativeCoreStopped'] = await invoke('stopListener', '') == true;
    try {
      final probe = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(seconds: 2));
      probe.destroy();
      evidence['listenerReleased'] = false;
    } on SocketException {
      evidence['listenerReleased'] = true;
    }
    evidence['systemProxyChanged'] = false;
    evidence['tunEnabled'] = false;
    stdout.writeln(jsonEncode(evidence));
  } catch (error) {
    evidence['failure'] =
        error is SolutionError ? error.code : error.runtimeType.toString();
    stdout.writeln(jsonEncode(evidence));
    exitCode = 1;
  } finally {
    stderr.writeln('Cleaning probe');
    proxy?.close(force: true);
    coreSocket?.destroy();
    if (core != null) {
      try {
        await core.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        core.kill();
      }
    }
    stderr.writeln('Closing core server');
    if (server != null) await server.close();
    if (temporary != null && await temporary.exists())
      await temporary.delete(recursive: true);
    api.close();
    // A pending platform DNS lookup can otherwise keep the one-shot VM alive.
    await stdout.flush();
    await stderr.flush();
    exit(exitCode);
  }
}
