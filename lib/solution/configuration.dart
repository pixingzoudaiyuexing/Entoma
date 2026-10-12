import 'dart:convert';
import 'package:yaml/yaml.dart';
import 'api.dart';

// JSON is a YAML subset. Re-encoding also removes YAML aliases and custom tags.
String prepareSubscription(String source) {
  if (utf8.encode(source).length > 4 * 1024 * 1024) {
    throw const SolutionError('INVALID_RESPONSE');
  }
  var nodes = 0;
  dynamic plain(dynamic value, [int depth = 0]) {
    if (++nodes > 100000 || depth > 64) {
      throw const SolutionError('INVALID_RESPONSE');
    }
    if (value is Map) {
      return value.map<String, dynamic>((key, value) {
        if (key is! String) throw const SolutionError('INVALID_RESPONSE');
        return MapEntry(key, plain(value, depth + 1));
      });
    }
    if (value is List) {
      return value.map((item) => plain(item, depth + 1)).toList();
    }
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    throw const SolutionError('INVALID_RESPONSE');
  }

  final data = object(plain(loadYaml(source)));
  final proxies = objects(data['proxies']);
  if (proxies.isEmpty ||
      proxies.length > 5000 ||
      data.containsKey('proxy-providers') ||
      data.containsKey('rule-providers') ||
      data.containsKey('script')) {
    throw const SolutionError('INVALID_RESPONSE');
  }
  final names = proxies.map((proxy) => string(proxy['name'])).toList();
  if (names.toSet().length != names.length) {
    throw const SolutionError('INVALID_RESPONSE');
  }
  for (final proxy in proxies) {
    string(proxy['type']);
    if (proxy.containsKey('skip-cert-verify')) {
      proxy['skip-cert-verify'] = false;
    }
    final plugin = proxy['plugin-opts'];
    if (plugin is Map && plugin.containsKey('skip-cert-verify')) {
      plugin['skip-cert-verify'] = false;
    }
  }
  data['proxies'] = proxies;
  final groups = objects(data['proxy-groups']).toList();
  final groupNames = groups.map((g) => string(g['name'])).toSet();
  if (groups.isEmpty || groupNames.length != groups.length) {
    throw const SolutionError('INVALID_RESPONSE');
  }
  var autoName = 'Entoma 自动选择';
  var fallbackName = 'Entoma 故障转移';
  while (groupNames.contains(autoName) || names.contains(autoName)) {
    autoName += ' ';
  }
  while (groupNames.contains(fallbackName) || names.contains(fallbackName)) {
    fallbackName += ' ';
  }
  groups.addAll([
    {
      'name': autoName,
      'type': 'url-test',
      'proxies': names,
      'url': 'https://www.gstatic.com/generate_204',
      'interval': 300,
      'tolerance': 50,
    },
    {
      'name': fallbackName,
      'type': 'fallback',
      'proxies': names,
      'url': 'https://www.gstatic.com/generate_204',
      'interval': 300,
    },
  ]);
  for (final group in groups) {
    if (group['type'] == 'select') {
      group['proxies'] = [autoName, fallbackName, ...group['proxies'] as List];
      break;
    }
  }
  // Only data-plane fields are accepted from remote subscription content.
  const allowed = {
    'proxies',
    'proxy-groups',
    'rules',
    'dns',
    'hosts',
    'mode',
    'unified-delay',
    'ipv6',
    'tcp-concurrent',
  };
  data.removeWhere((key, _) => !allowed.contains(key));
  if (data['dns'] is Map) (data['dns'] as Map).remove('listen');
  data['allow-lan'] = false;
  data['bind-address'] = '127.0.0.1';
  data['proxy-groups'] = groups;
  return jsonEncode(data);
}
