import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'journal_storage.dart';
import 'vault.dart';

export 'vault.dart';

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
  String? journalNotice;
  Map<String, dynamic>? account;
  Map<String, dynamic>? overview;
  int? balanceMinor;
  String currencySymbol = '';
  final Set<String> pendingMutations = {};
  final Set<String> _ticketCloseRecoveries = {};
  Future<void> _writes = Future.value();
  final Map<String, List<String>> _journal = {};
  Future<void> Function(String? nextEmail)? onAccountChange;

  SolutionSession(this.api, this.vault);
  bool get authenticated => _token != null;
  bool get mutationStorageTrusted => _journalReady;

  Future<void> _persist(int expected, {Set<String> completed = const {}}) {
    final completion = _writes.catchError((_) {}).then((_) async {
      if (generation != expected) return;
      final candidate = Map<String, List<String>>.from(_journal);
      final remaining = pendingMutations.difference(completed);
      if (email != null) candidate[email!] = remaining.toList();
      final sessionData = _token == null
          ? null
          : jsonEncode({
              'token': _token,
              'email': email,
              'pending': remaining.toList(),
            });
      if (!_journalReady && completed.isNotEmpty) {
        throw const SolutionError('JOURNAL_UNAVAILABLE');
      }
      if (_journalReady) {
        try {
          await vault.writeJournal(jsonEncode(candidate));
        } catch (_) {
          _journalReady = false;
          journalNotice = const SolutionError('JOURNAL_UNAVAILABLE').toString();
          rethrow;
        }
      }
      if (generation != expected) return;
      await vault.write(sessionData);
      if (generation == expected) {
        if (_journalReady) {
          _journal
            ..clear()
            ..addAll(candidate);
        }
        pendingMutations.removeAll(completed);
      }
    });
    _writes = completion;
    return completion;
  }

  bool _journalReady = false;
  Future<void>? _journalLoading;
  Future<void> _loadJournal() =>
      _journalLoading ??= _readJournal().whenComplete(() {
        _journalLoading = null;
      });
  Future<void> _readJournal() async {
    if (_journalReady) return;
    final journal = await vault.readJournal();
    final loaded = <String, List<String>>{};
    if (journal != null) {
      loaded.addAll(parseJournalEntries(jsonDecode(journal)));
    }
    _journal
      ..clear()
      ..addAll(loaded);
    _journalReady = true;
    journalNotice = null;
  }

  Future<bool> restore({
    bool removeLegacyCredentials = true,
    bool synchronizeProfiles = true,
  }) async {
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
      try {
        await _loadJournal();
      } catch (_) {
        if (expected == generation) {
          _journalReady = false;
          journalNotice = const SolutionError('JOURNAL_UNAVAILABLE').toString();
        }
      }
      final value = await vault.read();
      if (expected != generation) return false;
      if (value != null) {
        final data = object(jsonDecode(value));
        final token = string(data['token']);
        final address = string(data['email']);
        final backup = data['pending'];
        if (backup != null &&
            (backup is! List || backup.any((v) => v is! String || v.isEmpty))) {
          throw const SolutionError('STORAGE_ERROR');
        }
        _token = token;
        email = address;
        pendingMutations.addAll(_journal[address] ?? []);
        if (backup is List) pendingMutations.addAll(backup.cast<String>());
        if (_journalReady) _journal[address] = pendingMutations.toList();
      }
      storageRestored = true;
      notice = null;
    } catch (_) {
      notice = const SolutionError('STORAGE_ERROR').toString();
    } finally {
      if (expected == generation) {
        initialized = true;
        notifyListeners();
      }
    }
    if (synchronizeProfiles && storageRestored && expected == generation) {
      await onAccountChange?.call(email);
    }
    if (authenticated && expected == generation) unawaited(refreshAccount());
    return storageRestored && expected == generation;
  }

  Future<void> authenticate(
    String address,
    String password, {
    bool register = false,
    String? emailCode,
    String? inviteCode,
  }) async {
    if (busy) throw const SolutionError('OPERATION_IN_PROGRESS');
    busy = true;
    final expected = ++generation;
    api.cancelRequests();
    notifyListeners();
    try {
      await _loadJournal();
    } catch (_) {
      if (expected == generation) {
        _journalReady = false;
        journalNotice = const SolutionError('JOURNAL_UNAVAILABLE').toString();
      }
    }
    if (expected != generation) throw const SolutionError('STALE_SESSION');
    notice = null;
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
    } catch (error) {
      if (expected == generation) {
        notice = error is SolutionError
            ? error.toString()
            : const SolutionError('INVALID_RESPONSE').toString();
        notifyListeners();
      }
      rethrow;
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
    if (method != 'GET' && !_journalReady) {
      throw const SolutionError('JOURNAL_UNAVAILABLE');
    }
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
    if (busy) throw const SolutionError('OPERATION_IN_PROGRESS');
    if (!_journalReady) throw const SolutionError('JOURNAL_UNAVAILABLE');
    final orderId = key.startsWith('checkout:')
        ? key.substring(9)
        : key.startsWith('cancel:')
            ? key.substring(7)
            : null;
    if (pendingMutations.contains(key) ||
        (orderId != null && orderOperationPending(orderId))) {
      throw const SolutionError('MUTATION_PENDING');
    }
    return _performMutation(key, action, generation);
  }

  bool orderOperationPending(String id) =>
      pendingMutations.contains('checkout:$id') ||
      pendingMutations.contains('cancel:$id');

  Future<T> _performMutation<T>(
      String key, Future<T> Function(MutationContext) action, int expected,
      {bool alreadyPending = false}) async {
    pendingMutations.add(key);
    notifyListeners();
    try {
      await _persist(expected); // Fail closed before sending a mutation.
    } catch (_) {
      if (expected == generation) {
        if (!alreadyPending) pendingMutations.remove(key);
        notifyListeners();
      }
      throw const SolutionError('STORAGE_ERROR');
    }
    try {
      if (expected != generation || !authenticated) {
        throw const SolutionError('STALE_SESSION');
      }
      final value = await action(MutationContext(this, expected));
      if (expected != generation) throw const SolutionError('STALE_SESSION');
      try {
        await _persist(expected, completed: {key});
        if (expected != generation) throw const SolutionError('STALE_SESSION');
      } catch (_) {
        if (expected == generation) pendingMutations.add(key);
        throw const SolutionError('STORAGE_ERROR', outcomeUnknown: true);
      }
      return value;
    } on SolutionError catch (error) {
      if (expected == generation &&
          !alreadyPending &&
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

  Future<void> _completeReadback(Set<String> keys, int expected) async {
    if (expected != generation) throw const SolutionError('STALE_SESSION');
    // Authoritative reads stay available during quarantine, but cannot repair
    // an incomplete multi-account journal or release any of its locks.
    if (!_journalReady) return;
    if (!keys.any(pendingMutations.contains)) return;
    try {
      await _persist(expected, completed: keys);
    } catch (_) {
      throw const SolutionError('STORAGE_ERROR');
    }
    if (expected != generation) throw const SolutionError('STALE_SESSION');
    notifyListeners();
  }

  Future<SolutionOrder> readOrder(String id, int expected) async {
    final order = SolutionOrder(object(await request(
      '/api/v1/orders/${Uri.encodeComponent(id)}',
      expectedGeneration: expected,
    )));
    if (order.id != id) throw const SolutionError('INVALID_RESPONSE');
    // Pending can include an active payment session. Only terminal readback
    // releases the shared checkout/cancel lock; never infer payment absence.
    if (order.terminal) {
      await _completeReadback({'checkout:$id', 'cancel:$id'}, expected);
    }
    return order;
  }

  Future<Map<String, dynamic>> readTicket(String id, int expected) async {
    final ticket = object(await request(
      '/api/v1/tickets/${Uri.encodeComponent(id)}',
      expectedGeneration: expected,
    ));
    if (ticket['id'] != id || !{'open', 'closed'}.contains(ticket['status'])) {
      throw const SolutionError('INVALID_RESPONSE');
    }
    if (ticket['status'] == 'closed') {
      await _completeReadback({'ticket:close:$id'}, expected);
    }
    return ticket;
  }

  // Called only after a new explicit user confirmation. V2Board close writes
  // the owner's ticket to status=closed; repeating it has no payment/reply side
  // effects. Keep the old journal until success or authoritative closed readback.
  Future<void> retryTicketClose(String id, int expected) async {
    final key = 'ticket:close:$id';
    final flight = '$expected:$key';
    if (expected != generation) throw const SolutionError('STALE_SESSION');
    if (busy || !_ticketCloseRecoveries.add(flight)) {
      throw const SolutionError('OPERATION_IN_PROGRESS');
    }
    try {
      if (!_journalReady) throw const SolutionError('STORAGE_ERROR');
      if (!pendingMutations.contains(key)) {
        throw const SolutionError('MUTATION_PENDING');
      }
      final ticket = await readTicket(id, expected);
      if (ticket['status'] == 'closed') return;
      if (expected != generation) throw const SolutionError('STALE_SESSION');
      await _performMutation(
          key,
          (mutation) => mutation.request(
                '/api/v1/tickets/${Uri.encodeComponent(id)}/close',
                successField: 'closed',
              ),
          expected,
          alreadyPending: true);
    } finally {
      _ticketCloseRecoveries.remove(flight);
    }
  }

  Future<void> acknowledgeNewIntent(String key, int expected) async {
    if (!_journalReady) throw const SolutionError('JOURNAL_UNAVAILABLE');
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
    await _persist(expected, completed: {key});
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

  Future<void>? _clearFlight;
  bool _removeOwnedOnClear = false;
  Future<void> clear({bool expired = false}) {
    _removeOwnedOnClear = _removeOwnedOnClear || !expired;
    return _clearFlight ??= _clear(expired: expired).whenComplete(() {
      _clearFlight = null;
      _removeOwnedOnClear = false;
    });
  }

  Future<void> _clear({required bool expired}) async {
    if (email != null && _journalReady)
      _journal[email!] = pendingMutations.toList();
    final expected = ++generation;
    api.cancelRequests();
    _token = null;
    email = null;
    account = null;
    overview = null;
    balanceMinor = null;
    pendingMutations.clear();
    busy = true;
    initialized = true;
    notice = expired ? const SolutionError('AUTH_FAILED').toString() : null;
    notifyListeners();
    var storageFailed = false;
    try {
      if (_journalReady)
        await _persist(expected);
      else
        await vault.write(null);
    } catch (_) {
      storageFailed = true;
      // Deleting the account token must still be attempted after a journal error.
      final removal = _writes.catchError((_) {}).then((_) async {
        if (expected == generation) await vault.write(null);
      });
      _writes = removal;
      try {
        await removal;
      } catch (_) {}
    } finally {
      try {
        if (_removeOwnedOnClear && expected == generation)
          await onAccountChange?.call(null);
      } finally {
        if (expected == generation) {
          busy = false;
          notifyListeners();
        }
      }
    }
    if (storageFailed) throw const SolutionError('STORAGE_ERROR');
  }
}

final solutionSessionProvider = ChangeNotifierProvider<SolutionSession>((ref) {
  final api = SolutionApi();
  final session = SolutionSession(
      api,
      IntegritySessionVault(NativeSessionVault(api.origin.origin),
          PreferencesJournalWitness(api.origin.origin)));
  ref.onDispose(api.close);
  return session;
});
