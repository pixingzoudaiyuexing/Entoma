import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import "package:path/path.dart";

import 'proxy_platform_interface.dart';

enum ProxyTypes { http, https, socks }

class Proxy extends ProxyPlatform {
  static String url = "127.0.0.1";
  final String _operatingSystem;
  bool _ownsLinuxProxy = false;
  Proxy() : _operatingSystem = Platform.operatingSystem;
  @visibleForTesting
  Proxy.forPlatform(this._operatingSystem);

  Future<Map<String, dynamic>> helperStatus() async =>
      await const MethodChannel('proxy')
          .invokeMapMethod<String, dynamic>('HelperStatus') ??
      <String, dynamic>{};
  Future<Map<String, dynamic>> registerHelper() async =>
      await const MethodChannel('proxy')
          .invokeMapMethod<String, dynamic>('RegisterHelper') ??
      <String, dynamic>{};
  Future<Map<String, dynamic>> unregisterHelper() async =>
      await const MethodChannel('proxy')
          .invokeMapMethod<String, dynamic>('UnregisterHelper') ??
      <String, dynamic>{};

  @override
  Future<ProxyStatus> getProxyStatus(int port, List<String> bypassDomain) =>
      ProxyPlatform.instance.getProxyStatus(port, bypassDomain);

  @override
  Future<bool?> startProxy(
    int port, [
    List<String> bypassDomain = const [],
  ]) async {
    final result = switch (_operatingSystem) {
      "macos" => await ProxyPlatform.instance.startProxy(port, bypassDomain),
      "linux" => await _startProxyWithLinux(port, bypassDomain),
      "windows" => await ProxyPlatform.instance.startProxy(port, bypassDomain),
      String() => false,
    };
    if (result == true && _operatingSystem == 'linux') _ownsLinuxProxy = true;
    return result;
  }

  @override
  Future<bool?> stopProxy() async {
    // Native snapshots are the authority, including partially failed starts.
    // Native stop without an owned snapshot is a no-op. A Dart success flag
    // cannot decide whether a native restoration still needs to be retried.
    if (_operatingSystem == 'linux' && !_ownsLinuxProxy) return true;
    final result = switch (_operatingSystem) {
      "macos" => await ProxyPlatform.instance.stopProxy(),
      "linux" => await _stopProxyWithLinux(),
      "windows" => await ProxyPlatform.instance.stopProxy(),
      String() => false,
    };
    if (result == true) _ownsLinuxProxy = false;
    return result;
  }

  @override
  Future<bool?> startAutoDns() async => _operatingSystem == 'macos'
      ? await ProxyPlatform.instance.startAutoDns()
      : true;

  @override
  Future<bool?> stopAutoDns() async => _operatingSystem == 'macos'
      ? await ProxyPlatform.instance.stopAutoDns()
      : true;

  Future<bool> _startProxyWithLinux(int port, List<String> bypassDomain) async {
    try {
      final homeDir = Platform.environment['HOME']!;
      final configDir = join(homeDir, ".config");
      final cmdList = List<List<String>>.empty(growable: true);
      final desktop = Platform.environment['XDG_CURRENT_DESKTOP'];
      final isKDE = desktop == "KDE";
      if (isKDE) {
        cmdList.add(
          [
            "kwriteconfig5",
            "--file",
            "$configDir/kioslaverc",
            "--group",
            "Proxy Settings",
            "--key",
            "ProxyType",
            "1"
          ],
        );
        cmdList.add(
          [
            "kwriteconfig5",
            "--file",
            "$configDir/kioslaverc",
            "--group",
            "Proxy Settings",
            "--key",
            "NoProxyFor",
            bypassDomain.join(",")
          ],
        );
      } else {
        cmdList.add(
          ["gsettings", "set", "org.gnome.system.proxy", "mode", "manual"],
        );
        final ignoreHosts = "\"['${bypassDomain.join("', '")}']\"";
        cmdList.add(
          [
            "gsettings",
            "set",
            "org.gnome.system.proxy",
            "ignore-hosts",
            ignoreHosts
          ],
        );
      }
      for (final type in ProxyTypes.values) {
        if (!isKDE) {
          cmdList.add(
            [
              "gsettings",
              "set",
              "org.gnome.system.proxy.${type.name}",
              "host",
              url
            ],
          );
          cmdList.add(
            [
              "gsettings",
              "set",
              "org.gnome.system.proxy.${type.name}",
              "port",
              "$port"
            ],
          );
          cmdList.add(
            [
              "gsettings",
              "set",
              "org.gnome.system.proxy.${type.name}",
              "port",
              "$port"
            ],
          );
          cmdList.add(
            [
              "gsettings",
              "set",
              "org.gnome.system.proxy.${type.name}",
              "port",
              "$port"
            ],
          );
        }
        if (isKDE) {
          cmdList.add(
            [
              "kwriteconfig5",
              "--file",
              "$configDir/kioslaverc",
              "--group",
              "Proxy Settings",
              "--key",
              "${type.name}Proxy",
              "${type.name}://$url:$port"
            ],
          );
        }
      }
      for (final cmd in cmdList) {
        await Process.run(cmd[0], cmd.sublist(1), runInShell: true);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _stopProxyWithLinux() async {
    try {
      final homeDir = Platform.environment['HOME']!;
      final configDir = join(homeDir, ".config/");
      final cmdList = List<List<String>>.empty(growable: true);
      final desktop = Platform.environment['XDG_CURRENT_DESKTOP'];
      final isKDE = desktop == "KDE";
      if (isKDE) {
        cmdList.add(
          [
            "kwriteconfig5",
            "--file",
            "$configDir/kioslaverc",
            "--group",
            "Proxy Settings",
            "--key",
            "ProxyType",
            "0"
          ],
        );
      } else {
        cmdList.add(
          ["gsettings", "set", "org.gnome.system.proxy", "mode", "none"],
        );
      }
      for (final cmd in cmdList) {
        await Process.run(cmd[0], cmd.sublist(1));
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
