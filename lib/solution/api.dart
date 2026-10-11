import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const solutionOrigin = String.fromEnvironment(
  'SOLUTION_ORIGIN',
  defaultValue: 'https://cc-solution-stg.482658.xyz',
);

class SolutionError implements Exception {
  final String code;
  final bool outcomeUnknown;
  const SolutionError(this.code, {this.outcomeUnknown = false});
  bool get unauthorized => code == 'AUTH_FAILED' || code == 'AUTH_REQUIRED';
  @override
  String toString() => switch (code) {
        'AUTH_FAILED' || 'AUTH_REQUIRED' => '登录已失效，请重新登录',
        'VALIDATION_ERROR' => '请检查填写的内容',
        'NETWORK_ERROR' || 'UPSTREAM_TIMEOUT' => '网络暂时不可用，请稍后重试',
        'STALE_SESSION' => '账户已切换，请刷新后继续',
        'SUBSCRIPTION_ACCESS_UNAVAILABLE' => '当前账户暂无可用订阅',
        'MUTATION_PENDING' => '上次操作结果尚未确认，请先查看最新记录',
        'STORAGE_ERROR' => '无法安全保存登录信息，请检查系统密钥存储',
        'CHALLENGE_REQUIRED' => '当前注册需要网页人机验证，请联系服务方提供验证入口',
        'INVALID_RESPONSE' => '服务返回了无法识别的内容，请稍后重试',
        _ => '操作未完成，请刷新后重试',
      };
}

Map<String, dynamic> object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const SolutionError('INVALID_RESPONSE');
  }
  return value;
}

String string(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const SolutionError('INVALID_RESPONSE');
  }
  return value;
}

int integer(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) {
    throw const SolutionError('INVALID_RESPONSE');
  }
  return value;
}

List<Map<String, dynamic>> objects(Object? value) {
  if (value is! List) throw const SolutionError('INVALID_RESPONSE');
  return value.map(object).toList(growable: false);
}

Uri secureOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const SolutionError('INVALID_ORIGIN');
  }
  return Uri.parse(uri.origin);
}

class SolutionApi {
  final Uri origin;
  final http.Client _client;
  final Duration timeout;
  final Set<Completer<void>> _requests = {};
  SolutionApi({
    String baseUrl = solutionOrigin,
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
  })  : origin = secureOrigin(baseUrl),
        _client = client ??
            IOClient(
                HttpClient()..connectionTimeout = const Duration(seconds: 10));

  // No retries: a lost POST response may follow an upstream commit.
  Future<Object?> call(
    String path, {
    String method = 'GET',
    String? token,
    Map<String, dynamic>? body,
  }) async {
    if (!path.startsWith('/api/v1/') ||
        path.contains('://') ||
        path.contains('#')) {
      throw ArgumentError('Only Solution API resources are permitted');
    }
    final abort = Completer<void>();
    _requests.add(abort);
    final request = http.AbortableRequest(
      method,
      origin.resolve(path),
      abortTrigger: abort.future,
    )
      ..followRedirects = false
      ..headers['User-Agent'] = 'Entoma/0.1.0'
      ..headers['Accept'] = 'application/json';
    if (token != null) {
      if (token.isEmpty || RegExp(r'[\x00-\x20\x7f]').hasMatch(token)) {
        throw const SolutionError('AUTH_REQUIRED');
      }
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final mutation = method != 'GET';
    try {
      final result = await (() async {
        final response = await _client.send(request);
        final bytes = await _read(response, 2 * 1024 * 1024);
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw SolutionError('INVALID_RESPONSE', outcomeUnknown: mutation);
        }
        Map<String, dynamic> envelope;
        try {
          envelope = object(jsonDecode(utf8.decode(bytes)));
        } catch (_) {
          throw SolutionError('INVALID_RESPONSE', outcomeUnknown: mutation);
        }
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            envelope['ok'] != true) {
          final code = envelope['error'] is Map
              ? (envelope['error'] as Map)['code']
              : null;
          throw SolutionError(
            code is String ? code : 'INVALID_RESPONSE',
            outcomeUnknown: mutation && response.statusCode >= 500,
          );
        }
        return envelope['data'];
      })()
          .timeout(
        timeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw SolutionError('NETWORK_ERROR', outcomeUnknown: mutation);
        },
      );
      return result;
    } on SolutionError {
      rethrow;
    } catch (_) {
      throw SolutionError('NETWORK_ERROR', outcomeUnknown: mutation);
    } finally {
      _requests.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Uint8List> download(String accessUrl) async {
    final uri = Uri.tryParse(accessUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.origin != origin.origin ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const SolutionError('INVALID_RESPONSE');
    }
    final abort = Completer<void>();
    _requests.add(abort);
    try {
      return await (() async {
        // An independent request carries NO account Authorization or cookies.
        final request =
            http.AbortableRequest('GET', uri, abortTrigger: abort.future)
              ..followRedirects = false
              ..headers['User-Agent'] = 'Clash.Meta/1.19.32 Entoma/0.1.0';
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          throw const SolutionError('NETWORK_ERROR');
        }
        return _read(response, 4 * 1024 * 1024);
      })()
          .timeout(
        timeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw const SolutionError('NETWORK_ERROR');
        },
      );
    } on SolutionError {
      rethrow;
    } catch (_) {
      throw const SolutionError('NETWORK_ERROR');
    } finally {
      _requests.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Uint8List> _read(http.StreamedResponse response, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in response.stream) {
      if (builder.length + bytes.length > limit) {
        throw const SolutionError('INVALID_RESPONSE');
      }
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  void cancelRequests() {
    for (final abort in _requests.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  void close() {
    cancelRequests();
    _client.close();
  }
}

enum OrderStatus { pending, processing, completed, cancelled, adjusted }

class SolutionOrder {
  final String id;
  final OrderStatus status;
  final int amountMinor;
  final DateTime createdAt;
  SolutionOrder(Map<String, dynamic> data)
      : id = string(data['id']),
        status = OrderStatus.values.firstWhere(
          (v) => v.name == data['status'],
          orElse: () => throw const SolutionError('INVALID_RESPONSE'),
        ),
        amountMinor = integer(data['amountMinor']),
        createdAt = DateTime.parse(string(data['createdAt']));
  bool get terminal =>
      status == OrderStatus.completed ||
      status == OrderStatus.cancelled ||
      status == OrderStatus.adjusted;
  String get statusText => switch (status) {
        OrderStatus.pending => '待付款',
        OrderStatus.processing => '确认中',
        OrderStatus.completed => '已完成',
        OrderStatus.cancelled => '已取消',
        OrderStatus.adjusted => '已调整',
      };
}

class CheckoutAction {
  final String type;
  final String? payload;
  CheckoutAction(Map<String, dynamic> data)
      : type = string(data['type']),
        payload = data['type'] == 'qrcode'
            ? string(data['data'])
            : data['type'] == 'redirect'
                ? string(data['target'])
                : null {
    if (!{'finished', 'qrcode', 'redirect'}.contains(type)) {
      throw const SolutionError('INVALID_RESPONSE', outcomeUnknown: true);
    }
    if (type == 'redirect') {
      final uri = Uri.tryParse(payload!);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const SolutionError('INVALID_RESPONSE', outcomeUnknown: true);
      }
    }
  }
}
