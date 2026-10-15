import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'vault.dart';

const journalWitnessPrefix = 'entoma.journal.integrity.v1.';

abstract class JournalWitness {
  Object get scope;
  Future<String?> read();
  Future<void> write(String value);
}

// This independent, non-secret checkpoint detects missing/rolled-back secure
// journal items. It contains no account, token, operation ID or business payload.
// Android's pinned legacy preferences implementation uses synchronous commit().
class PreferencesJournalWitness implements JournalWitness {
  final String key;
  PreferencesJournalWitness(String origin)
      : key = '$journalWitnessPrefix${sha256.convert(utf8.encode(origin))}';
  @override
  Object get scope => key;
  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, value)) {
      throw const SolutionError('JOURNAL_UNAVAILABLE');
    }
    await prefs.reload();
    if (prefs.getString(key) != value) {
      throw const SolutionError('JOURNAL_UNAVAILABLE');
    }
  }
}

Map<String, List<String>> parseJournalEntries(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const SolutionError('JOURNAL_UNAVAILABLE');
  }
  final entries = <String, List<String>>{};
  for (final entry in raw.entries) {
    if (entry.key.isEmpty ||
        entry.value is! List ||
        (entry.value as List).any((v) => v is! String || v.isEmpty)) {
      throw const SolutionError('JOURNAL_UNAVAILABLE');
    }
    entries[entry.key] = (entry.value as List).cast<String>();
  }
  return entries;
}

class IntegritySessionVault implements SessionVault {
  final SessionVault native;
  final JournalWitness witness;
  static final Map<Object, Future<void>> _queues = {};
  String? _expectedDigest;
  IntegritySessionVault(this.native, this.witness);

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _queues[witness.scope] ?? Future<void>.value();
    final operation = previous.catchError((_) {}).then((_) => action());
    final tail = operation.then<void>((_) {}, onError: (_) {});
    _queues[witness.scope] = tail;
    tail.then((_) {
      if (identical(_queues[witness.scope], tail)) {
        _queues.remove(witness.scope);
      }
    });
    return operation;
  }

  @override
  Future<String?> read() => native.read();
  @override
  Future<void> write(String? value) => native.write(value);

  String _digest(String raw) => sha256.convert(utf8.encode(raw)).toString();
  bool _isEnvelope(Map<String, dynamic> raw) => raw.containsKey('schema');
  String _unwrap(String raw) {
    final decoded = object(jsonDecode(raw));
    if (!_isEnvelope(decoded)) return jsonEncode(parseJournalEntries(decoded));
    if (decoded['schema'] != 2 || decoded.length != 2) {
      throw const SolutionError('JOURNAL_UNAVAILABLE');
    }
    return jsonEncode(parseJournalEntries(decoded['entries']));
  }

  // Dirty checkpoints are never cleared by login, logout, risk acknowledgement,
  // or a GET. Even an old digest can be a lost completion write; fail closed.
  Future<String> _load() async {
    try {
      final checkpointRaw = await witness.read();
      final journal = await native.readJournal();
      if (checkpointRaw != null) {
        final checkpoint = object(jsonDecode(checkpointRaw));
        if (checkpoint.length != 3 ||
            checkpoint['schema'] != 1 ||
            checkpoint['state'] != 'ready' ||
            journal == null ||
            checkpoint['digest'] != _digest(journal)) {
          throw const SolutionError('JOURNAL_UNAVAILABLE');
        }
        final entries = _unwrap(journal);
        _expectedDigest = _digest(journal);
        return entries;
      }
      if (journal != null) {
        final decoded = object(jsonDecode(journal));
        // A v2 record without its witness is partial state loss, not an upgrade.
        if (_isEnvelope(decoded)) {
          throw const SolutionError('JOURNAL_UNAVAILABLE');
        }
        final entries = parseJournalEntries(decoded);
        await _commit(entries);
        return jsonEncode(entries);
      }
      // Legacy login always wrote a journal. Session present + journal missing
      // is therefore not a legitimate empty legacy journal.
      if (await native.read() != null) {
        throw const SolutionError('JOURNAL_UNAVAILABLE');
      }
      // No local evidence survives complete app-data loss. A truly fresh store
      // and deletion of ALL records/witness are indistinguishable; server-side
      // idempotency is required to cover that documented boundary.
      await _commit({});
      return '{}';
    } catch (_) {
      throw const SolutionError('JOURNAL_UNAVAILABLE');
    }
  }

  Future<void> _commit(Map<String, List<String>> entries) async {
    final raw = jsonEncode({'schema': 2, 'entries': entries});
    final digest = _digest(raw);
    await witness
        .write(jsonEncode({'schema': 1, 'state': 'dirty', 'digest': digest}));
    await native.writeJournal(raw);
    if (await native.readJournal() != raw) {
      throw const SolutionError('JOURNAL_UNAVAILABLE');
    }
    await witness
        .write(jsonEncode({'schema': 1, 'state': 'ready', 'digest': digest}));
    _expectedDigest = digest;
  }

  @override
  Future<String?> readJournal() => _serial(_load);

  @override
  Future<void> writeJournal(String value) => _serial(() async {
        try {
          final entries = parseJournalEntries(jsonDecode(value));
          final expected = _expectedDigest;
          await _load(); // Revalidate durable state before each replacement.
          if (expected == null || expected != _expectedDigest) {
            throw const SolutionError('JOURNAL_UNAVAILABLE');
          }
          await _commit(entries);
        } catch (_) {
          _expectedDigest = null;
          throw const SolutionError('JOURNAL_UNAVAILABLE');
        }
      });
}
