import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

abstract class SessionVault {
  Future<String?> read();
  Future<void> write(String? value);
  Future<String?> readJournal();
  Future<void> writeJournal(String value);
}

class NativeSessionVault implements SessionVault {
  final FlutterSecureStorage storage;
  final String key;
  NativeSessionVault(String origin, {FlutterSecureStorage? storage})
      : storage = storage ??
            const FlutterSecureStorage(
                mOptions: MacOsOptions(usesDataProtectionKeychain: false)),
        key = 'entoma.session.v1.$origin';
  @override
  Future<String?> read() => storage.read(key: key);
  @override
  Future<void> write(String? value) => value == null
      ? storage.delete(key: key)
      : storage.write(key: key, value: value);
  @override
  Future<String?> readJournal() => storage.read(key: '$key.pending');
  @override
  Future<void> writeJournal(String value) =>
      storage.write(key: '$key.pending', value: value);
}

class MutationContext {
  final SolutionSession session;
  final int generation;
  const MutationContext(this.session, this.generation);
  Future<Object?> request(
    String path, {
    String method = 'POST',
    Map<String, dynamic>? body,
    String? successField,
  }) async {
    final data = await session.request(
      path,
      method: method,
      body: body,
      expectedGeneration: generation,
    );
    if (successField != null && object(data)[successField] != true) {
      throw const SolutionError('INVALID_RESPONSE', outcomeUnknown: true);
    }
    return data;
  }
}

class SolutionSession extends ChangeNotifier {
  final SolutionApi api;
  final SessionVault vault;
  String? _token;
  String? email;
  int generation = 0;
  bool initialized = false;
  bool busy = false;
  String? notice;
  Map<String, dynamic>? account;
  Map<String, dynamic>? overview;
  int? balanceMinor;
  String currencySymbol = '';
  final Set<String> pendingMutations = {};
  Future<void> _writes = Future.value();
  final Map<String, List<String>> _journal = {};
  Future<void> Function(String? nextEmail)? onAccountChange;

  SolutionSession(this.api, this.vault);
  bool get authenticated => _token != null;

  Future<void> _persist(int expected) {
    final completion = _writes.catchError((_) {}).then((_) async {
      if (generation != expected) return;
      if (email != null) _journal[email!] = pendingMutations.toList();
      await vault.writeJournal(jsonEncode(_journal));
      if (generation != expected) return;
      await vault.write(
        _token == null
            ? null
            : jsonEncode({
                'token': _token,
                'email': email,
                'pending': pendingMutations.toList(),
              }),
      );
    });
    _writes = completion;
    return completion;
  }

  Future<void> restore({bool removeLegacyCredentials = true}) async {
    final expected = generation;
    var storageRestored = false;
    try {
      if (removeLegacyCredentials) {
        final preferences = await SharedPreferences.getInstance();
        // Legacy sessions are not trusted or migrated from plaintext.
        for (final key in [
          'xboard_saved_password',
          'xboard_remember_password',
          'xboard_token',
          'xboard_auth_token',
          'xboard_subscription_info',
          'xboard_domain_subscription',
          'xboard_user_info',
          'xboard_domain_user',
        ]) {
          await preferences.remove(key);
        }
      }
      final journal = await vault.readJournal();
      if (journal != null) {
        for (final entry in object(jsonDecode(journal)).entries) {
          if (entry.value is! List ||
              (entry.value as List).any((item) => item is! String)) {
            throw const SolutionError('STORAGE_ERROR');
          }
          _journal[entry.key] = (entry.value as List).cast<String>();
        }
      }
      final value = await vault.read();
      if (expected != generation) return;
      if (value != null) {
        final data = object(jsonDecode(value));
        _token = string(data['token']);
        email = data['email'] as String?;
        pendingMutations.addAll(_journal[email] ?? []);
        if (data['pending'] is List) {
          pendingMutations.addAll(
            (data['pending'] as List).whereType<String>(),
          );
        }
      }
      storageRestored = true;
    } catch (_) {
      notice = const SolutionError('STORAGE_ERROR').toString();
    } finally {
      if (expected == generation) {
        initialized = true;
        notifyListeners();
      }
    }
    if (storageRestored && expected == generation)
      await onAccountChange?.call(email);
    if (authenticated && expected == generation) unawaited(refreshAccount());
  }

  Future<void> authenticate(
    String address,
    String password, {
    bool register = false,
    String? emailCode,
    String? inviteCode,
  }) async {
    if (busy) return;
    busy = true;
    notice = null;
    final expected = ++generation;
    api.cancelRequests();
    notifyListeners();
    try {
      final data = object(
        await api.call(
          register ? '/api/v1/auth/register' : '/api/v1/auth/login',
          method: 'POST',
          body: {
            'email': address.trim(),
            'password': password,
            if (emailCode?.isNotEmpty == true) 'emailCode': emailCode,
            if (inviteCode?.isNotEmpty == true) 'inviteCode': inviteCode,
          },
        ),
      );
      if (expected != generation) throw const SolutionError('STALE_SESSION');
      final token = string(data['accessToken']);
      if (data['tokenType'] != 'Bearer') {
        throw const SolutionError('INVALID_RESPONSE');
      }
      final me = object(await api.call('/api/v1/me', token: token));
      final canonicalEmail = string(me['email']);
      if (expected != generation) throw const SolutionError('STALE_SESSION');
      await onAccountChange?.call(canonicalEmail);
      if (expected != generation) throw const SolutionError('STALE_SESSION');
      pendingMutations
        ..clear()
        ..addAll(_journal[canonicalEmail] ?? []);
      _token = token;
      email = canonicalEmail;
      try {
        await _persist(expected);
      } catch (_) {
        _token = null;
        throw const SolutionError('STORAGE_ERROR');
      }
      initialized = true;
      await refreshAccount();
    } finally {
      if (expected == generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<Object?> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    int? expectedGeneration,
  }) async {
    final expected = expectedGeneration ?? generation;
    if (expected != generation) throw const SolutionError('STALE_SESSION');
    final token = _token;
    if (token == null) throw const SolutionError('AUTH_REQUIRED');
    try {
      final result = await api.call(
        path,
        method: method,
        token: token,
        body: body,
      );
      if (expected != generation) throw const SolutionError('STALE_SESSION');
      return result;
    } on SolutionError catch (error) {
      if (expected == generation && error.unauthorized) {
        await clear(expired: true);
      }
      rethrow;
    }
  }

  Future<T> mutate<T>(
    String key,
    Future<T> Function(MutationContext) action,
  ) async {
    if (pendingMutations.contains(key)) {
      throw const SolutionError('MUTATION_PENDING');
    }
    final expected = generation;
    pendingMutations.add(key);
    notifyListeners();
    try {
      await _persist(expected); // Fail closed before sending a mutation.
    } catch (_) {
      if (expected == generation) pendingMutations.remove(key);
      throw const SolutionError('STORAGE_ERROR');
    }
    try {
      if (expected != generation || !authenticated) {
        throw const SolutionError('STALE_SESSION');
      }
      final value = await action(MutationContext(this, expected));
      if (expected != generation) throw const SolutionError('STALE_SESSION');
      pendingMutations.remove(key);
      try {
        await _persist(expected);
      } catch (_) {
        pendingMutations.add(key);
        throw const SolutionError('STORAGE_ERROR', outcomeUnknown: true);
      }
      return value;
    } on SolutionError catch (error) {
      if (expected == generation &&
          !error.outcomeUnknown &&
          error.code != 'STALE_SESSION' &&
          error.code != 'INVALID_RESPONSE') {
        pendingMutations.remove(key);
        await _persist(expected);
      }
      rethrow;
    } catch (_) {
      // Unknown failures, including malformed success DTOs, remain locked.
      throw const SolutionError('INVALID_RESPONSE', outcomeUnknown: true);
    } finally {
      if (expected == generation) notifyListeners();
    }
  }

  Future<void> reconcileOrder(SolutionOrder order) async {
    if (!order.terminal) return;
    final expected = generation;
    final old = pendingMutations.toSet();
    pendingMutations.remove('checkout:${order.id}');
    pendingMutations.remove('cancel:${order.id}');
    try {
      await _persist(expected);
    } catch (_) {
      pendingMutations
        ..clear()
        ..addAll(old);
      rethrow;
    }
    notifyListeners();
  }

  Future<void> acknowledgeNewIntent(String key, int expected) async {
    final path = key == 'order:create'
        ? '/api/v1/orders'
        : key == 'ticket:create'
            ? '/api/v1/tickets'
            : key.startsWith('ticket:reply:')
                ? '/api/v1/tickets/${Uri.encodeComponent(key.substring(13))}'
                : key == 'referral:create'
                    ? '/api/v1/referrals'
                    : null;
    if (path == null || expected != generation) {
      throw const SolutionError('STALE_SESSION');
    }
    await request(path, expectedGeneration: expected);
    if (expected != generation) throw const SolutionError('STALE_SESSION');
    pendingMutations.remove(key);
    try {
      await _persist(expected);
    } catch (_) {
      pendingMutations.add(key);
      rethrow;
    }
    notifyListeners();
  }

  Future<void> refreshAccount() async {
    final expected = generation;
    try {
      final me = object(await request('/api/v1/me'));
      string(me['email']);
      if (!{'active', 'expired', 'disabled'}.contains(me['status'])) {
        throw const SolutionError('INVALID_RESPONSE');
      }
      if (expected != generation) return;
      account = me;
      email = me['email'] as String;
      notice = null;
      notifyListeners();
      await Future.wait([
        (() async {
          final value = object(await request('/api/v1/subscription/overview'));
          final traffic = object(value['traffic']);
          for (final key in [
            'uploadedBytes',
            'downloadedBytes',
            'allowanceBytes',
          ]) {
            integer(traffic[key]);
          }
          if (expected == generation) overview = value;
        })(),
        (() async {
          final value = object(await request('/api/v1/wallet'));
          if (expected == generation) {
            balanceMinor = integer(value['balanceMinor']);
          }
        })(),
        (() async {
          final value = object(await request('/api/v1/config/account'));
          if (expected == generation) {
            currencySymbol = string(value['currencySymbol']);
          }
        })(),
      ]);
    } catch (error) {
      if (expected == generation) {
        notice = error is SolutionError
            ? error.toString()
            : const SolutionError('INVALID_RESPONSE').toString();
      }
    } finally {
      if (expected == generation) notifyListeners();
    }
  }

  Future<void> clear({bool expired = false}) async {
    final expected = ++generation;
    api.cancelRequests();
    _token = null;
    email = null;
    account = null;
    overview = null;
    balanceMinor = null;
    pendingMutations.clear();
    busy = false;
    initialized = true;
    notice = expired ? const SolutionError('AUTH_FAILED').toString() : null;
    notifyListeners();
    await _persist(expected);
    if (!expired) await onAccountChange?.call(null);
  }
}

final solutionSessionProvider = ChangeNotifierProvider<SolutionSession>((ref) {
  final api = SolutionApi();
  final session = SolutionSession(api, NativeSessionVault(api.origin.origin));
  ref.onDispose(api.close);
  return session;
});
