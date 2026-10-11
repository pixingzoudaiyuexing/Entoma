import 'dart:io';
import 'package:crypto/crypto.dart';

Future<void> main(List<String> arguments) async {
  stdout.writeln(await sha256.bind(File(arguments.single).openRead()).first);
}
