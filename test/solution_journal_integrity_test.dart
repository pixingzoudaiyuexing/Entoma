import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/journal_storage.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:fl_clash/solution/account_page.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'solution_test.dart' show MemoryVault, accountResponse, success;

class BrokenJournalVault extends MemoryVault {
  bool unreadable = true;
  @override
  Future<String?> readJournal() async {
    if (unreadable) throw StateError('fixture cipher error');
    return super.readJournal();
  }
}

class MemoryWitness implements JournalWitness {
  @override
  Object get scope => this;
  String? value;
  int writes = 0;
  int? failWrite;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    if (++writes == failWrite) throw StateError('fixture interrupted commit');
    value = next;
  }
}

class InterruptedNativeVault extends MemoryVault {
  bool dropWrite = false;
  @override
  Future<void> writeJournal(String next) async {
    if (dropWrite) return;
    await super.writeJournal(next);
  }
}

class DelayedJournalVault extends MemoryVault {
  final started = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<String?> readJournal() async {
    if (!started.isCompleted) started.complete();
    await resume.future;
    return super.readJournal();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android native read never requests deletion or automatic migration',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'fixture_cipher_error');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final vault = NativeSessionVault(solutionOrigin);
    await expectLater(vault.readJournal(), throwsA(isA<PlatformException>()));
    final options = (calls.single.arguments as Map)['options'] as Map;
    expect(options['resetOnError'], 'false');
    expect(options['migrateOnAlgorithmChange'], 'false');
    expect(calls.map((c) => c.method), ['read']);
  });

  test('unreadable journal keeps intact session reads but blocks every POST',
      () async {
    final vault = BrokenJournalVault()
      ..value = jsonEncode({
        'token': 'fixture-token',
        'email': 'fixture@example.com',
        'pending': ['checkout:order-1']
      });
    var posts = 0;
    final api = SolutionApi(client: MockClient((r) async {
      if (r.method != 'GET') posts++;
      return accountResponse(r);
    }));
    addTearDown(api.close);
    final session = SolutionSession(api, vault);
    expect(await session.restore(removeLegacyCredentials: false), isTrue);
    expect(session.authenticated, isTrue);
    await session.refreshAccount();
    expect(session.balanceMinor, 12345);
    await expectLater(session.request('/api/v1/orders', method: 'POST'),
        throwsA(isA<SolutionError>()));
    await expectLater(session.mutate('checkout:order-1', (_) async => true),
        throwsA(isA<SolutionError>()));
    await expectLater(
        session.acknowledgeNewIntent('order:create', session.generation),
        throwsA(isA<SolutionError>()));
    expect(posts, 0);
  });

  test('login and logout cannot overwrite an unreadable logged-out journal',
      () async {
    final vault = BrokenJournalVault()
      ..journal = '{"fixture@example.com":["checkout:order-1"]}';
    final api =
        SolutionApi(client: MockClient((r) async => accountResponse(r)));
    addTearDown(api.close);
    final session = SolutionSession(api, vault);
    await session.authenticate('fixture@example.com', 'fixture-password');
    expect(session.authenticated, isTrue);
    expect(vault.journal, contains('checkout:order-1'));
    await expectLater(session.mutate('checkout:order-1', (_) async => true),
        throwsA(isA<SolutionError>()));
    await session.clear();
    expect(vault.value, isNull);
    expect(vault.journal, contains('checkout:order-1'));
    await session.authenticate('fixture@example.com', 'fixture-password');
    await expectLater(session.mutate('checkout:order-1', (_) async => true),
        throwsA(isA<SolutionError>()));
  });

  test('legacy migration preserves logged-out UNKNOWN for all accounts',
      () async {
    final native = MemoryVault()
      ..journal = jsonEncode({
        'fixture@example.com': ['checkout:order-1'],
        'other@example.com': ['ticket:create']
      });
    final witness = MemoryWitness();
    final vault = IntegritySessionVault(native, witness);
    expect(jsonDecode((await vault.readJournal())!), {
      'fixture@example.com': ['checkout:order-1'],
      'other@example.com': ['ticket:create']
    });
    expect(jsonDecode(native.journal!)['schema'], 2);
    expect(jsonDecode(witness.value!)['state'], 'ready');
    final api =
        SolutionApi(client: MockClient((r) async => accountResponse(r)));
    addTearDown(api.close);
    final session = SolutionSession(api, vault);
    await session.authenticate('fixture@example.com', 'fixture-password');
    await expectLater(session.mutate('checkout:order-1', (_) async => true),
        throwsA(isA<SolutionError>()));
    await session.clear();
    expect(native.value, isNull);
    expect(jsonDecode((await vault.readJournal())!)['other@example.com'],
        ['ticket:create']);
  });

  for (final damage in [
    'missing-journal',
    'missing-witness',
    'missing-other-account',
    'dirty',
    'malformed',
    'rollback'
  ]) {
    test('cold $damage cannot be unlocked by login logout or acknowledgement',
        () async {
      final native = MemoryVault();
      final witness = MemoryWitness();
      final first = IntegritySessionVault(native, witness);
      await first.readJournal();
      final old = native.journal;
      await first.writeJournal(jsonEncode({
        'fixture@example.com': ['checkout:order-1'],
        'other@example.com': ['checkout:order-2']
      }));
      switch (damage) {
        case 'missing-journal':
          native.journal = null;
        case 'missing-witness':
          witness.value = null;
        case 'missing-other-account':
          native.journal = jsonEncode({
            'schema': 2,
            'entries': {
              'fixture@example.com': ['checkout:order-1']
            }
          });
        case 'dirty':
          final record = jsonDecode(witness.value!);
          record['state'] = 'dirty';
          witness.value = jsonEncode(record);
        case 'malformed':
          native.journal = '{bad fixture';
        case 'rollback':
          native.journal = old;
      }
      final damaged = native.journal;
      final checkpoint = witness.value;
      final vault = IntegritySessionVault(native, witness);
      var financialPosts = 0;
      final api = SolutionApi(client: MockClient((r) async {
        if (r.url.path == '/api/v1/orders' && r.method == 'POST') {
          financialPosts++;
        }
        return accountResponse(r);
      }));
      addTearDown(api.close);
      final session = SolutionSession(api, vault);
      await session.authenticate('fixture@example.com', 'fixture-password');
      expect(session.authenticated, isTrue);
      expect(session.mutationStorageTrusted, isFalse);
      expect(session.journalNotice, isNotNull);
      await expectLater(session.mutate('checkout:order-1', (_) async => true),
          throwsA(isA<SolutionError>()));
      await expectLater(
          session.acknowledgeNewIntent('order:create', session.generation),
          throwsA(isA<SolutionError>()));
      await session.clear();
      await session.authenticate('fixture@example.com', 'fixture-password');
      await expectLater(session.request('/api/v1/orders', method: 'POST'),
          throwsA(isA<SolutionError>()));
      expect(financialPosts, 0);
      expect(native.journal, damaged);
      expect(witness.value, checkpoint);
    });
  }

  for (final boundary in [
    'dirty-write',
    'native-write',
    'readback',
    'ready-write'
  ]) {
    test('interruption at $boundary prevents POST and survives cold restore',
        () async {
      final native = InterruptedNativeVault();
      final witness = MemoryWitness();
      final vault = IntegritySessionVault(native, witness);
      final api =
          SolutionApi(client: MockClient((r) async => accountResponse(r)));
      addTearDown(api.close);
      final session = SolutionSession(api, vault);
      await session.authenticate('fixture@example.com', 'fixture-password');
      witness.writes = 0;
      witness.failWrite = boundary == 'dirty-write'
          ? 1
          : boundary == 'ready-write'
              ? 2
              : null;
      native.failWrites = boundary == 'native-write';
      native.dropWrite = boundary == 'readback';
      var sent = 0;
      await expectLater(session.mutate('checkout:order-1', (_) async => sent++),
          throwsA(isA<SolutionError>()));
      expect(sent, 0);
      witness.failWrite = null;
      native.failWrites = false;
      native.dropWrite = false;
      final cold = SolutionSession(api, IntegritySessionVault(native, witness));
      expect(await cold.restore(removeLegacyCredentials: false), isTrue);
      expect(cold.authenticated, isTrue);
      if (boundary != 'dirty-write') {
        expect(cold.mutationStorageTrusted, isFalse);
        await expectLater(cold.mutate('checkout:order-1', (_) async => sent++),
            throwsA(isA<SolutionError>()));
      }
      expect(sent, 0);
    });
  }

  test('legacy session present with missing journal cannot initialize empty',
      () async {
    final native = MemoryVault()..value = '{"token":"fixture-token"}';
    final witness = MemoryWitness();
    final vault = IntegritySessionVault(native, witness);
    await expectLater(vault.readJournal(), throwsA(isA<SolutionError>()));
    expect(native.journal, isNull);
    expect(witness.value, isNull);
  });

  test('stale vault cannot overwrite another instance pending operation',
      () async {
    final native = MemoryVault();
    final witness = MemoryWitness();
    final first = IntegritySessionVault(native, witness);
    final second = IntegritySessionVault(native, witness);
    await first.readJournal();
    await second.readJournal();
    await second.writeJournal('{"other@example.com":["checkout:order-2"]}');
    await expectLater(first.writeJournal('{}'), throwsA(isA<SolutionError>()));
    expect(native.journal, contains('checkout:order-2'));
    await expectLater(first.writeJournal('{}'), throwsA(isA<SolutionError>()));
    expect(native.journal, contains('checkout:order-2'));
  });

  test('old login completion cannot quarantine a newer authenticated session',
      () async {
    final vault = DelayedJournalVault()..journal = '{}';
    final api =
        SolutionApi(client: MockClient((r) async => accountResponse(r)));
    addTearDown(api.close);
    final session = SolutionSession(api, vault);
    final old = session.authenticate('fixture@example.com', 'fixture-password');
    final oldAssertion = expectLater(old, throwsA(isA<SolutionError>()));
    await vault.started.future;
    await session.clear();
    final current =
        session.authenticate('fixture@example.com', 'fixture-password');
    vault.resume.complete();
    await oldAssertion;
    await current;
    expect(session.authenticated, isTrue);
    expect(session.mutationStorageTrusted, isTrue);
    expect(session.journalNotice, isNull);
  });

  test('session pending backup remains protected across account switching',
      () async {
    final native = MemoryVault()
      ..value = jsonEncode({
        'token': 'fixture-token',
        'email': 'fixture@example.com',
        'pending': ['checkout:backup-order']
      })
      ..journal = '{}';
    final witness = MemoryWitness();
    var active = 'fixture@example.com';
    final api = SolutionApi(client: MockClient((r) async {
      if (r.url.path.endsWith('/login')) {
        active = jsonDecode(r.body)['email'];
      }
      if (r.url.path == '/api/v1/me') {
        return success(
            {'email': active, 'status': 'active', 'expiresAt': null});
      }
      return accountResponse(r);
    }));
    addTearDown(api.close);
    final session =
        SolutionSession(api, IntegritySessionVault(native, witness));
    await session.restore(removeLegacyCredentials: false);
    await session.authenticate('other@example.com', 'fixture-password');
    expect(session.pendingMutations, isEmpty);
    await session.authenticate('fixture@example.com', 'fixture-password');
    expect(session.pendingMutations, contains('checkout:backup-order'));
  });

  test('complete local state loss is indistinguishable from a fresh install',
      () async {
    final native = MemoryVault();
    final witness = MemoryWitness();
    final vault = IntegritySessionVault(native, witness);
    expect(await vault.readJournal(), '{}');
    // This explicit boundary must be covered by a server-side operation ledger.
    native.journal = null;
    native.value = null;
    witness.value = null;
    expect(await IntegritySessionVault(native, witness).readJournal(), '{}');
  });

  test('configuration reset preserves independent integrity checkpoints',
      () async {
    SharedPreferences.setMockInitialValues({
      '${journalWitnessPrefix}fixture': '{"state":"dirty"}',
      'config': 'fixture settings'
    });
    final prefs = await SharedPreferences.getInstance();
    final prior = preferences.sharedPreferencesCompleter;
    await prior.future;
    preferences.sharedPreferencesCompleter = Completer()..complete(prefs);
    addTearDown(() => preferences.sharedPreferencesCompleter = prior);
    await preferences.clearPreferences();
    expect(
        prefs.getString('${journalWitnessPrefix}fixture'), '{"state":"dirty"}');
    expect(prefs.containsKey('config'), isFalse);
  });

  test('quarantine allows terminal reads without releasing or replacing locks',
      () async {
    final vault = BrokenJournalVault()
      ..value = jsonEncode({
        'token': 'fixture-token',
        'email': 'fixture@example.com',
        'pending': ['checkout:order-1', 'ticket:close:1']
      });
    final api = SolutionApi(client: MockClient((r) async {
      expect(r.method, 'GET');
      if (r.url.path == '/api/v1/orders/order-1') {
        return success({
          'id': 'order-1',
          'status': 'completed',
          'amountMinor': 100,
          'createdAt': '2026-01-01T00:00:00Z'
        });
      }
      if (r.url.path == '/api/v1/tickets/1') {
        return success({'id': '1', 'status': 'closed'});
      }
      return accountResponse(r);
    }));
    addTearDown(api.close);
    final session = SolutionSession(api, vault);
    await session.restore(removeLegacyCredentials: false);
    expect((await session.readOrder('order-1', session.generation)).terminal,
        isTrue);
    expect((await session.readTicket('1', session.generation))['status'],
        'closed');
    expect(session.pendingMutations, ['checkout:order-1', 'ticket:close:1']);
    expect(session.mutationStorageTrusted, isFalse);
    expect(vault.journal, isNull);
  });

  testWidgets(
      'journal failure displays protection while account reads stay usable',
      (tester) async {
    final native = BrokenJournalVault()
      ..value = jsonEncode({
        'token': 'fixture-token',
        'email': 'fixture@example.com',
        'pending': []
      });
    final api =
        SolutionApi(client: MockClient((r) async => accountResponse(r)));
    addTearDown(api.close);
    final session = SolutionSession(api, native);
    await session.restore(removeLegacyCredentials: false);
    await tester.pumpWidget(ProviderScope(
        overrides: [solutionSessionProvider.overrideWith((_) => session)],
        child: const MaterialApp(home: Scaffold(body: SolutionAccountPage()))));
    await tester.pumpAndSettle();
    expect(find.textContaining('重新登录不会解除保护'), findsOneWidget);
    expect(find.text('刷新账户'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
