import 'dart:convert';
import 'dart:async';
import 'package:fl_clash/common/core_launch.dart';
import 'package:fl_clash/common/core_launch_deadline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancel while hash is delayed cannot launch a process later', () async {
    final gate = CoreLaunchEpoch();
    final hashReady = Completer<void>();
    var launches = 0;
    final epoch = gate.begin();
    final operation = () async {
      await hashReady.future;
      if (gate.isCurrent(epoch)) launches++;
    }();
    gate.cancel();
    hashReady.complete();
    await operation;
    expect(launches, 0);
  });
  test('cancel before process handle arrives kills only the retired handle',
      () async {
    final gate = CoreLaunchEpoch();
    final arrived = Completer<void>();
    var retiredKills = 0;
    var replacementKills = 0;
    final epoch = gate.begin();
    final operation = () async {
      await arrived.future;
      return gate.acceptHandle(epoch, () => retiredKills++);
    }();
    gate.cancel();
    final replacement = gate.begin();
    arrived.complete();
    expect(await operation, isFalse);
    expect(retiredKills, 1);
    expect(gate.acceptHandle(replacement, () => replacementKills++), isTrue);
    expect(replacementKills, 0);
    expect(
        gate.acceptHandle(replacement, () => replacementKills++,
            ownerCurrent: false),
        isFalse);
    expect(replacementKills, 1);
  });
  testWidgets(
      'administrator wait longer than 60 seconds does not consume IPC deadline',
      (tester) async {
    final failures = <CoreLaunchPhase>[];
    final deadline = CoreLaunchDeadline(failures.add)
      ..waitingForAuthorization();
    await tester.pump(const Duration(seconds: 90));
    expect(failures, isEmpty);
    deadline.executableLaunched();
    await tester.pump(const Duration(seconds: 59));
    expect(failures, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(failures, [CoreLaunchPhase.authentication]);
  });
  testWidgets('missing authorization marker has a distinct bounded failure',
      (tester) async {
    final failures = <CoreLaunchPhase>[];
    CoreLaunchDeadline(failures.add).waitingForAuthorization();
    await tester.pump(const Duration(minutes: 5));
    expect(failures, [CoreLaunchPhase.authorization]);
  });
  testWidgets(
      'authentication and cancelled sessions ignore late marker and timer',
      (tester) async {
    final failures = <CoreLaunchPhase>[];
    final deadline = CoreLaunchDeadline(failures.add)
      ..waitingForAuthorization();
    deadline.cancel();
    deadline.executableLaunched();
    await tester.pump(const Duration(minutes: 10));
    expect(failures, isEmpty);
  });
  test('readiness marker is session-local and quoted before exec', () {
    const path =
        '/private/tmp/entoma-fixture/launch-0123456789abcdef0123456789abcdef.ready';
    final script = elevatedMacCommand(
        "/Applications/Owner's App/core", 'fixture',
        readyPath: path);
    final command = jsonDecode(script.substring('do shell script '.length,
        script.length - ' with administrator privileges'.length)) as String;
    expect(command, contains('umask 022; set -C;'));
    expect(command, contains(' > ${shellQuote(path)} && exec '));
    expect(command, contains(shellQuote("/Applications/Owner's App/core")));
    expect(
        () => elevatedMacCommand('/tmp/core', 'fixture',
            readyPath: '/tmp/shared'),
        throwsArgumentError);
    expect(
        () => elevatedMacCommand('/tmp/core', 'fixture', readyPath: '$path\n'),
        throwsArgumentError);
  });
}
