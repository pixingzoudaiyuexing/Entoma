import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/core_launch.dart';
import 'package:flutter_test/flutter_test.dart';

const _markerName = 'launch-0123456789abcdef0123456789abcdef.ready';

Future<Directory> _privateFixture() async {
  final directory =
      await Directory('/private/tmp').createTemp('entoma-marker-test-');
  final result = await Process.run('/bin/chmod', ['700', directory.path]);
  expect(result.exitCode, 0);
  expect((await directory.stat()).mode & 0x1ff, 0x1c0); // 0700
  return directory;
}

Future<({int pid, int exitCode})> _runMarker(String path) async {
  // Decode the production AppleScript string, then run only its ordinary shell
  // command. No osascript, administrator prompt, elevation or proxy core.
  final script =
      elevatedMacCommand('/usr/bin/true', 'nonsecret-fixture', readyPath: path);
  final command = jsonDecode(script.substring('do shell script '.length,
      script.length - ' with administrator privileges'.length)) as String;
  final process = await Process.start('/bin/sh', ['-c', command]);
  final results = await Future.wait([
    process.exitCode,
    process.stdout.drain<void>(),
    process.stderr.drain<void>(),
  ]);
  return (pid: process.pid, exitCode: results.first as int);
}

void main() {
  test(
      'actual readiness shell creates readable PID-only marker in private directory',
      () async {
    final directory = await _privateFixture();
    try {
      final marker = File('${directory.path}/$_markerName');
      final result = await _runMarker(marker.path);
      expect(result.exitCode, 0);
      expect(await FileSystemEntity.type(marker.path, followLinks: false),
          FileSystemEntityType.file);
      expect((await marker.stat()).mode & 0x1ff,
          0x1a4); // 0644 (root writes; GUI may read)
      final content = await marker.readAsString();
      expect(content, result.pid.toString());
      expect(RegExp(r'^[1-9][0-9]*$').hasMatch(content), isTrue);
      expect((await directory.stat()).mode & 0x1ff, 0x1c0);
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  test('actual readiness shell refuses an existing marker without replacing it',
      () async {
    final directory = await _privateFixture();
    try {
      final marker = File('${directory.path}/$_markerName');
      await marker.writeAsString('existing-nonsecret-fixture');
      final result = await _runMarker(marker.path);
      expect(result.exitCode, isNot(0));
      expect(await marker.readAsString(), 'existing-nonsecret-fixture');
      expect((await directory.stat()).mode & 0x1ff, 0x1c0);
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  for (final dangling in [false, true]) {
    test(
        'actual readiness shell refuses ${dangling ? "dangling" : "existing"} symlink and leaves target untouched',
        () async {
      final directory = await _privateFixture();
      try {
        final target = File('${directory.path}/fixture-target');
        if (!dangling) await target.writeAsString('target-nonsecret-fixture');
        final marker = Link('${directory.path}/$_markerName');
        await marker.create(target.path);
        final result = await _runMarker(marker.path);
        expect(result.exitCode, isNot(0));
        expect(await FileSystemEntity.type(marker.path, followLinks: false),
            FileSystemEntityType.link);
        expect(await marker.target(), target.path);
        if (dangling) {
          expect(await target.exists(), isFalse);
        } else {
          expect(await target.readAsString(), 'target-nonsecret-fixture');
        }
        expect((await directory.stat()).mode & 0x1ff, 0x1c0);
      } finally {
        await directory.delete(recursive: true);
      }
    }, skip: !Platform.isMacOS);
  }
}
