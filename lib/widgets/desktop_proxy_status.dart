import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_clash/common/desktop_proxy.dart';

String desktopProxyLabel(DesktopProxyCoordinator coordinator) =>
    switch (coordinator.phase) {
      DesktopProxyPhase.disconnected => '未连接',
      DesktopProxyPhase.connecting => '连接中…',
      DesktopProxyPhase.connected => '已连接',
      DesktopProxyPhase.disconnecting => '断开中…',
      DesktopProxyPhase.failed => '操作失败',
    };

String desktopProxyFailure(Object? failure) {
  if (failure is PlatformException) {
    return switch (failure.code) {
      'HELPER_SIGNING_REQUIRED' => '此测试包未签名，系统代理服务暂不可用。',
      'HELPER_APPROVAL_REQUIRED' => '请在系统设置中允许 Entoma 后重试。',
      'HELPER_NOT_REGISTERED' => '请先启用系统代理服务。',
      'HELPER_NOT_FOUND' => '请先安装并启用已签名的系统代理服务。',
      'HELPER_REQUIRES_MACOS_13' => '系统代理服务需要 macOS 13 或更高版本。',
      'HELPER_OPERATION_UNKNOWN' ||
      'HELPER_RECOVERY_REQUIRED' ||
      'NETWORK_RESTORE_FAILED' =>
        '系统代理恢复尚未确认，请重试关闭后再连接。',
      _ => '系统代理未完成，请检查系统权限后重试。',
    };
  }
  return failure is StateError
      ? failure.message.toString()
      : '系统代理未完成，请检查配置和系统权限后重试。';
}

class DesktopProxyStatusText extends StatelessWidget {
  final DesktopProxyCoordinator coordinator;
  const DesktopProxyStatusText({super.key, required this.coordinator});
  @override
  Widget build(BuildContext context) => Text(
        coordinator.phase == DesktopProxyPhase.failed
            ? desktopProxyFailure(coordinator.failure)
            : desktopProxyLabel(coordinator),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: coordinator.phase == DesktopProxyPhase.failed
            ? TextStyle(color: Theme.of(context).colorScheme.error)
            : null,
      );
}
