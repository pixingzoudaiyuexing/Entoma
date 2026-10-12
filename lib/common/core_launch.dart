import 'dart:convert';

String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String elevatedMacCommand(String executable, String argument) {
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch('$executable$argument')) {
    throw ArgumentError('Control characters are not valid in a core command');
  }
  final command = 'exec ${shellQuote(executable)} ${shellQuote(argument)}';
  return 'do shell script ${jsonEncode(command)} with administrator privileges';
}
