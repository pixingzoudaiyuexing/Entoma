import 'dart:convert';

String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String elevatedMacCommand(String executable, String argument,
    {String? readyPath}) {
  if (RegExp(r'[\x00-\x1f\x7f]')
      .hasMatch('$executable$argument${readyPath ?? ''}')) {
    throw ArgumentError('Control characters are not valid in a core command');
  }
  if (readyPath != null &&
      !RegExp(r'^/private/tmp/entoma-[^/]+/launch-[0-9a-f]{32}\.ready$')
          .hasMatch(readyPath)) {
    throw ArgumentError(
        'Readiness marker must belong to the private IPC directory');
  }
  final marker = readyPath == null
      ? ''
      : 'umask 022; set -C; printf \'%s\' "\$\$" > ${shellQuote(readyPath)} && ';
  final command =
      '${marker}exec ${shellQuote(executable)} ${shellQuote(argument)}';
  return 'do shell script ${jsonEncode(command)} with administrator privileges';
}
