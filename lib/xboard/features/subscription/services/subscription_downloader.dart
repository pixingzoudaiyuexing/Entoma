import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/clash/core.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/core/core.dart';
import 'package:fl_clash/xboard/infrastructure/http/user_agent_config.dart';
import 'package:socks5_proxy/socks_client.dart';

// 初始化文件级日志器
final _logger = FileLogger('subscription_downloader.dart');

/// XBoard 订阅下载服务
///
/// 并发下载（直连 + 所有代理），第一个成功就获胜
class SubscriptionDownloader {
  static const Duration _downloadTimeout = Duration(seconds: 30);

  /// 下载订阅并返回 Profile（并发竞速）
  ///
  /// [url] 订阅URL
  /// [enableRacing] 是否启用竞速（默认 true，false时只使用直连）
  static Future<Profile> downloadSubscription(
    String url, {
    bool enableRacing = true,
  }) async {
    try {
      _logger.info('开始下载订阅: $url');

      final _DownloadResult result;

      if (!enableRacing) {
        // 禁用竞速：直接使用直连下载
        _logger.info('竞速已禁用，使用直连下载');
        result = await _downloadWithMethod(
          url,
          useProxy: false,
          cancelToken: _CancelToken(),
          taskIndex: 0,
        );
      } else {
        // 启用竞速：并发下载，第一个成功就获胜
        final proxies = XBoardConfig.allProxyUrls;
        _logger.info('开始并发下载 (${proxies.length + 1}种方式)');

        final cancelTokens = <_CancelToken>[];
        final tasks = <Future<_DownloadResult>>[];

        try {
          // 任务0: 直连下载
          final directToken = _CancelToken();
          cancelTokens.add(directToken);
          tasks.add(_downloadWithMethod(
            url,
            useProxy: false,
            cancelToken: directToken,
            taskIndex: 0,
          ));

          // 任务1+: 所有代理下载
          for (int i = 0; i < proxies.length; i++) {
            final proxyToken = _CancelToken();
            cancelTokens.add(proxyToken);
            tasks.add(_downloadWithMethod(
              url,
              useProxy: true,
              proxyUrl: proxies[i],
              cancelToken: proxyToken,
              taskIndex: i + 1,
            ));
          }

          // 等待第一个成功的任务（忽略失败的）
          result = await _waitForFirstSuccess(tasks);

          // 取消其他所有任务
          _logger.info('🏆 ${result.connectionType} 获胜！');
          for (final token in cancelTokens) {
            token.cancel();
          }

        } catch (e) {
          // 取消所有任务
          for (final token in cancelTokens) {
            token.cancel();
          }
          rethrow;
        }
      }

      // 验证配置
      _logger.info('验证订阅配置...');
      final validationMessage = await clashCore.validateConfig(result.content);
      if (validationMessage.isNotEmpty) {
        throw Exception('配置验证失败: $validationMessage');
      }
      _logger.info('✅ 订阅配置验证通过');

      // 创建并保存 Profile
      final profile = Profile.normal(url: url);
      final savedProfile = await profile.saveFileWithString(result.content);

      // 更新订阅信息
      final finalProfile = savedProfile.copyWith(
        label: result.label ?? savedProfile.id,
        subscriptionInfo: result.subscriptionInfo,
        lastUpdateDate: DateTime.now(),
      );

      _logger.info('✅ 订阅下载成功: ${finalProfile.label}');
      return finalProfile;

    } on TimeoutException catch (e) {
      _logger.error('订阅下载超时', e);
      throw Exception('下载超时: ${e.message}');
    } on SocketException catch (e) {
      _logger.error('网络连接失败', e);
      throw Exception('网络连接失败: ${e.message}');
    } on HttpException catch (e) {
      _logger.error('HTTP请求失败', e);
      throw Exception('HTTP请求失败: ${e.message}');
    } catch (e) {
      _logger.error('订阅下载失败', e);
      rethrow;
    }
  }

  /// 等待第一个成功的任务（忽略失败的）
  static Future<_DownloadResult> _waitForFirstSuccess(
    List<Future<_DownloadResult>> tasks,
  ) async {
    final completer = Completer<_DownloadResult>();
    int failedCount = 0;
    final errors = <Object>[];

    for (final task in tasks) {
      task.then((result) {
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      }).catchError((e) {
        failedCount++;
        errors.add(e);

        // 如果所有任务都失败了，抛出第一个错误
        if (failedCount == tasks.length && !completer.isCompleted) {
          _logger.error('所有下载任务都失败了', errors.first);
          completer.completeError(errors.first);
        }
      });
    }

    return completer.future;
  }

  /// 使用指定方式下载完整订阅内容
  static Future<_DownloadResult> _downloadWithMethod(
    String url, {
    required bool useProxy,
    String? proxyUrl,
    required _CancelToken cancelToken,
    required int taskIndex,
  }) async {
    final connectionType = useProxy ? '代理($proxyUrl)' : '直连';
    _logger.info('[任务$taskIndex] 开始下载: $connectionType');

    try {
      final result = await _downloadWithProxy(
        url,
        useProxy: useProxy,
        proxyUrl: proxyUrl,
        cancelToken: cancelToken,
      );

      _logger.info('[任务$taskIndex] 下载成功: $connectionType，大小: ${result.bytes.length} bytes');

      return _DownloadResult(
        content: result.content,
        connectionType: connectionType,
        label: result.label,
        subscriptionInfo: result.subscriptionInfo,
        bytes: result.bytes,
      );

    } catch (e) {
      if (cancelToken.isCancelled) {
        _logger.info('[任务$taskIndex] 已取消: $connectionType');
      } else {
        _logger.warning('[任务$taskIndex] 下载失败: $connectionType - $e');
      }
      rethrow;
    }
  }

  /// 使用代理下载订阅内容
  static Future<_DownloadRawResult> _downloadWithProxy(
    String url, {
    required bool useProxy,
    String? proxyUrl,
    required _CancelToken cancelToken,
  }) async {
    HttpClient? client;

    try {
      // 检查是否已取消
      if (cancelToken.isCancelled) {
        throw Exception('任务已取消');
      }

      // 创建 HttpClient
      client = HttpClient();
      client.connectionTimeout = _downloadTimeout;


      // 如果使用代理，配置 SOCKS5 代理
      if (useProxy && proxyUrl != null) {
        final proxyConfig = _parseProxyConfig(proxyUrl);
        final proxySettings = ProxySettings(
          InternetAddress(proxyConfig['host']!),
          int.parse(proxyConfig['port']!),
          username: proxyConfig['username'],
          password: proxyConfig['password'],
        );

        SocksTCPClient.assignToHttpClient(client, [proxySettings]);
      }

      // 发起请求
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);

      // 检查是否已取消
      if (cancelToken.isCancelled) {
        client.close(force: true);
        throw Exception('任务已取消');
      }

      // 设置请求头
      final userAgent = await UserAgentConfig.get(UserAgentScenario.subscription);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);

      // 检查是否已取消
      if (cancelToken.isCancelled) {
        client.close(force: true);
        throw Exception('任务已取消');
      }

      // 获取响应
      final response = await request.close().timeout(
        _downloadTimeout,
        onTimeout: () {
          throw TimeoutException('下载超时', _downloadTimeout);
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      // 检查是否已取消
      if (cancelToken.isCancelled) {
        client.close(force: true);
        throw Exception('任务已取消');
      }

      // 读取响应内容
      final bytes = await response.fold<List<int>>(
        <int>[],
        (previous, element) {
          if (cancelToken.isCancelled) {
            throw Exception('任务已取消');
          }
          return previous..addAll(element);
        },
      );
      final content = utf8.decode(bytes);

      // 解析响应头
      final disposition = response.headers.value('content-disposition');
      final userinfo = response.headers.value('subscription-userinfo');

      String? label;
      if (disposition != null) {
        // 从 content-disposition 提取文件名
        final match = RegExp(r'filename="?([^";\n]+)"?').firstMatch(disposition);
        if (match != null) {
          label = match.group(1)?.trim();
        }
      }

      final subscriptionInfo = userinfo != null
          ? SubscriptionInfo.formHString(userinfo)
          : null;

      return _DownloadRawResult(
        content: content,
        label: label,
        subscriptionInfo: subscriptionInfo,
        bytes: bytes,
      );

    } finally {
      if (cancelToken.isCancelled) {
        client?.close(force: true);
      } else {
        client?.close();
      }
    }
  }

  /// 解析代理配置
  ///
  /// 输入格式:
  /// - `socks5://user:pass@host:port`
  /// - `socks5://host:port`
  /// - `http://user:pass@host:port`
  ///
  /// 返回: { host, port, username?, password? }
  static Map<String, String?> _parseProxyConfig(String proxyUrl) {
    String url = proxyUrl.trim();

    // 去除协议前缀
    if (url.toLowerCase().startsWith('socks5://')) {
      url = url.substring(9);
    } else if (url.toLowerCase().startsWith('http://')) {
      url = url.substring(7);
    } else if (url.toLowerCase().startsWith('https://')) {
      url = url.substring(8);
    }

    String? username;
    String? password;
    String hostPort = url;

    // 解析认证信息 user:pass@host:port
    if (url.contains('@')) {
      final atIndex = url.lastIndexOf('@');
      final authPart = url.substring(0, atIndex);
      hostPort = url.substring(atIndex + 1);

      if (authPart.contains(':')) {
        final colonIndex = authPart.indexOf(':');
        username = authPart.substring(0, colonIndex);
        password = authPart.substring(colonIndex + 1);
      }
    }

    // 解析 host:port
    final colonIndex = hostPort.lastIndexOf(':');
    if (colonIndex == -1) {
      throw FormatException('代理配置格式错误，缺少端口号: $proxyUrl');
    }

    final host = hostPort.substring(0, colonIndex);
    final port = hostPort.substring(colonIndex + 1);

    if (host.isEmpty || port.isEmpty) {
      throw FormatException('代理配置格式错误: $proxyUrl');
    }

    return {
      'host': host,
      'port': port,
      'username': username,
      'password': password,
    };
  }
}

/// 取消令牌
class _CancelToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }
}

/// 下载结果（含连接类型）
class _DownloadResult {
  final String content;
  final String connectionType;
  final String? label;
  final SubscriptionInfo? subscriptionInfo;
  final List<int> bytes;

  _DownloadResult({
    required this.content,
    required this.connectionType,
    this.label,
    this.subscriptionInfo,
    required this.bytes,
  });
}

/// 下载原始结果
class _DownloadRawResult {
  final String content;
  final String? label;
  final SubscriptionInfo? subscriptionInfo;
  final List<int> bytes;

  _DownloadRawResult({
    required this.content,
    this.label,
    this.subscriptionInfo,
    required this.bytes,
  });
}
