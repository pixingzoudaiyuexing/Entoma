import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/clash/clash.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'configuration.dart';

import 'api.dart';
import 'session.dart';

class SolutionSubscription {
  final Ref ref;
  bool busy = false;
  Completer<void>? _transaction;
  SolutionSubscription(this.ref);

  String profileId(SolutionSession session) =>
      'entoma-${sha256.convert(utf8.encode('${session.api.origin.origin}\n${session.email}'))}';

  Future<void> refresh() async {
    if (busy) return;
    busy = true;
    _transaction = Completer<void>();
    final session = ref.read(solutionSessionProvider);
    final expected = session.generation;
    void check() {
      if (session.generation != expected || !session.authenticated) {
        throw const SolutionError('STALE_SESSION');
      }
    }

    File? staged;
    try {
      final access = object(await session.request('/api/v1/subscription'));
      if (access['eligible'] != true || access['accessUrl'] == null) {
        throw const SolutionError('SUBSCRIPTION_ACCESS_UNAVAILABLE');
      }
      final bytes = await session.api.download(string(access['accessUrl']));
      check();
      final yaml = prepareSubscription(utf8.decode(bytes));
      final validation = await clashCore.validateConfig(yaml);
      check();
      if (validation.isNotEmpty) throw const SolutionError('INVALID_RESPONSE');
      final id = profileId(session);
      final path = await appPath.getProfilePath(id);
      check();
      final target = File(path);
      await target.parent.create(recursive: true);
      staged = File('$path.staged');
      await staged.writeAsString(yaml, flush: true);
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['600', staged.path]);
        if (result.exitCode != 0) throw const SolutionError('STORAGE_ERROR');
      }
      check();
      final candidateFile = staged;
      await globalState.appController.runProfileTransaction(() async {
        File? backup;
        final previous = ref.read(profilesProvider).getProfile(id);
        final previousId = ref.read(currentProfileIdProvider);
        if (await target.exists())
          backup = await target.rename('$path.previous');
        try {
          check();
          await candidateFile.rename(path);
          check();
          final profile =
              (previous ?? Profile.normal(label: 'Entoma 订阅')).copyWith(
            id: id,
            url: '',
            autoUpdate: false,
            lastUpdateDate: DateTime.now(),
          );
          globalState.appController.setProfile(profile);
          ref.read(currentProfileIdProvider.notifier).value = id;
          await globalState.appController.applyProfile(silence: true);
          check();
          await globalState.appController.savePreferences();
          if (backup != null && await backup.exists()) await backup.delete();
        } catch (_) {
          if (await target.exists()) await target.delete();
          if (backup != null && await backup.exists())
            await backup.rename(path);
          if (previous != null) {
            globalState.appController.setProfile(previous);
          } else {
            ref.read(profilesProvider.notifier).deleteProfileById(id);
          }
          if (ref.read(currentProfileIdProvider) == id) {
            ref.read(currentProfileIdProvider.notifier).value = previousId;
          }
          try {
            if (ref.read(currentProfileIdProvider) != null) {
              await globalState.appController.applyProfile(silence: true);
            } else {
              await globalState.appController.updateStatus(false);
            }
          } catch (_) {
            await globalState.appController.updateStatus(false);
            throw const SolutionError('CONFIG_ROLLBACK_FAILED');
          }
          rethrow;
        }
      });
    } finally {
      try {
        if (staged != null && await staged.exists()) await staged.delete();
      } finally {
        busy = false;
        _transaction?.complete();
        _transaction = null;
      }
    }
  }

  Future<void> keepOnly(String? nextEmail) async {
    final pending = _transaction;
    if (pending != null) await pending.future;
    final session = ref.read(solutionSessionProvider);
    final keepId = nextEmail == null
        ? null
        : 'entoma-${sha256.convert(utf8.encode('${session.api.origin.origin}\n$nextEmail'))}';
    if (keepId != null) {
      final keepPath = await appPath.getProfilePath(keepId);
      final previous = File('$keepPath.previous');
      if (await previous.exists()) {
        final target = File(keepPath);
        if (await target.exists()) await target.delete();
        await previous.rename(keepPath);
      }
      final staged = File('$keepPath.staged');
      if (await staged.exists()) await staged.delete();
    }
    final owned = ref
        .read(profilesProvider)
        .where(
          (profile) =>
              RegExp(r'^entoma-[a-f0-9]{64}$').hasMatch(profile.id) &&
              profile.id != keepId,
        )
        .toList();
    if (owned.any(
      (profile) => profile.id == ref.read(currentProfileIdProvider),
    )) {
      await clashCore.closeConnections();
      await globalState.appController.updateStatus(false);
      final cleared = await clashCore.setupConfig(SetupParams(
          config: const {}, selectedMap: const {}, testUrl: defaultTestUrl));
      if (cleared.isNotEmpty)
        throw const SolutionError('CONFIG_ROLLBACK_FAILED');
      ref.read(currentProfileIdProvider.notifier).value = null;
    }
    for (final profile in owned) {
      final path = await appPath.getProfilePath(profile.id);
      for (final suffix in ['', '.previous', '.staged']) {
        final file = File('$path$suffix');
        if (await file.exists()) await file.delete();
      }
      ref.read(profilesProvider.notifier).deleteProfileById(profile.id);
    }
    if (ref.read(currentProfileIdProvider) == null) {
      final remaining = ref.read(profilesProvider);
      if (remaining.isNotEmpty) {
        ref.read(currentProfileIdProvider.notifier).value = remaining.first.id;
      }
    }
    final directory = Directory(await appPath.profilesPath);
    if (await directory.exists()) {
      await for (final entry in directory.list(followLinks: false)) {
        final name = entry.path.split(Platform.pathSeparator).last;
        final match =
            RegExp(r'^(entoma-[a-f0-9]{64})\.yaml(?:\.(?:staged|previous))?$')
                .firstMatch(name);
        if (match != null && match.group(1) != keepId && entry is File)
          await entry.delete();
      }
    }
    if (ref.read(currentProfileIdProvider) != null)
      await globalState.appController.applyProfile(silence: true);
    await globalState.appController.savePreferences();
  }
}

final solutionSubscriptionProvider = Provider(SolutionSubscription.new);
