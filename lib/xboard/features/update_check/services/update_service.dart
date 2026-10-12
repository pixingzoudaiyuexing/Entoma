import 'dart:io';
import 'package:fl_clash/xboard/core/core.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:fl_clash/common/common.dart';

// 初始化文件级日志器
final _logger = FileLogger('update_service.dart');

class UpdateService {
  /// Get the best update server URL from configuration
  Future<String> _getServerUrl() async {
    final updateUrl = XBoardConfig.updateUrl;
    if (updateUrl != null && updateUrl.isNotEmpty) {
      _logger.info('从配置获取更新URL: $updateUrl');
      return updateUrl;
    }
    
    throw Exception(appLocalizations.updateCheckServerUrlNotConfigured);
  }

  /// 获取所有可用的更新服务器URL
  Future<List<String>> _getAllServerUrls() async {
    final configUrls = XBoardConfig.allUpdateUrls;
    
    if (configUrls.isEmpty) {
      throw Exception(appLocalizations.updateCheckNoServerUrlsConfigured);
    }
    
    _logger.info('从配置获取到 ${configUrls.length} 个更新URL');
    return configUrls;
  }

  /// 检查更新（使用配置的更新服务器）
  Future<Map<String, dynamic>> checkForUpdatesWithFallback() async {
    final serverUrls = await _getAllServerUrls();
    
    for (int i = 0; i < serverUrls.length; i++) {
      try {
        _logger.info('尝试更新服务器 ${i + 1}/${serverUrls.length}: ${serverUrls[i]}');
        return await _checkForUpdatesFromUrl(serverUrls[i]);
      } catch (e) {
        _logger.error('更新服务器 ${serverUrls[i]} 失败', e);
        if (i == serverUrls.length - 1) {
          // 最后一个服务器也失败了，抛出异常
          rethrow;
        }
        // 继续尝试下一个服务器
        continue;
      }
    }
    
    throw Exception(appLocalizations.updateCheckAllServersUnavailable);
  }

  /// 从指定URL检查更新
  Future<Map<String, dynamic>> _checkForUpdatesFromUrl(String serverUrl) async {
    final currentVersion = await getCurrentVersion();
    final platform = _getPlatformName();
    final dio = Dio();
    final requestUrl = '$serverUrl/api/v1/check-update?version=$currentVersion&platform=$platform';
    
    _logger.info('发送更新检查请求: $requestUrl');
    dio.options.connectTimeout = const Duration(seconds: 15);
    dio.options.receiveTimeout = const Duration(seconds: 15);
    dio.options.validateStatus = (status) {
      return status != null && status < 600; // 接受所有小于600的状态码
    };
    
    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      return client;
    };
    
    final response = await dio.get(
      requestUrl,
      options: Options(
        headers: {
          'Accept': 'application/json',
        },
      ),
    );
    
    if (response.statusCode != 200) {
      final errorMessage = appLocalizations.updateCheckServerError(response.statusCode!);
      if (response.statusCode == 530) {
        throw Exception('$errorMessage - ${appLocalizations.updateCheckServerTemporarilyUnavailable}');
      } else {
        throw Exception('$errorMessage: ${response.data}');
      }
    }
    
    final responseData = response.data as Map<String, dynamic>;
    return {
      "currentVersion": currentVersion,
      "latestVersion": responseData["latest_version"]?.toString() ?? "",
      "hasUpdate": responseData["update_available"] == true,
      "updateUrl": responseData["download_url"]?.toString() ?? "",
      "releaseNotes": responseData["release_notes"]?.toString() ?? "",
      "forceUpdate": responseData["force_update"] == true,
    };
  }
  Future<String> getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }
  Future<Map<String, dynamic>> checkForUpdates() async {
    final serverUrl = await _getServerUrl();
    return await _checkForUpdatesFromUrl(serverUrl);
  }
  String _getPlatformName() {
    if (Platform.isAndroid) return "android";
    if (Platform.isIOS) return "ios";
    if (Platform.isWindows) return "windows";
    if (Platform.isMacOS) return "macos";
    if (Platform.isLinux) return "linux";
    return "unknown";
  }
}
