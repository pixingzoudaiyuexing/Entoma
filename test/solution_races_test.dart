import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/core_launch.dart';
import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/configuration.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'solution_test.dart' show MemoryVault, accountResponse, success;

class BlockingVault extends MemoryVault {
  Completer<void>? block;
  final started = Completer<void>();
  bool failCompletion = false;
  int writes = 0;
  @override
  Future<void> writeJournal(String next) async {
    writes++;
    final pending = block;
    if (pending != null) {
      block = null;
      started.complete();
      await pending.future;
    }
    if (failCompletion && writes == 2)
      throw StateError('completion persistence failed');
    await super.writeJournal(next);
  }
}

class AbortObservingClient extends http.BaseClient {
  final aborted = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    (request as http.AbortableRequest).abortTrigger!.then((_) {
      if (!aborted.isCompleted) aborted.complete();
      controller.addError(http.RequestAbortedException());
      controller.close();
    });
    return http.StreamedResponse(controller.stream, 200);
  }
}

class ReadFailureVault extends MemoryVault {
  bool failRead = true;
  @override
  Future<String?> readJournal() async {
    if (failRead) throw StateError('temporarily locked keychain');
    return super.readJournal();
  }
}

void main() {
  test('logout while pre-send storage is blocked prevents the old POST',
      () async {
    final vault = BlockingVault();
    var posts = 0;
    final session =
        SolutionSession(SolutionApi(client: MockClient((request) async {
      if (request.url.path == '/api/v1/orders') posts++;
      return accountResponse(request);
    })), vault);
    await session.authenticate('fixture@example.com', 'fixture-password');
    final block = Completer<void>();
    vault.block = block;
    final operation = session.mutate(
        'order:create', (mutation) => mutation.request('/api/v1/orders'));
    final assertion = expectLater(operation, throwsA(isA<SolutionError>()));
    await vault.started.future;
    final cleared = session.clear();
    block.complete();
    await cleared;
    await assertion;
    expect(posts, 0);
  });

  test(
      'completion journal failure followed by logout preserves the unknown operation',
      () async {
    final vault = BlockingVault();
    final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault);
    await session.authenticate('fixture@example.com', 'fixture-password');
    vault.writes = 0;
    vault.failCompletion = true;
    await expectLater(session.mutate('checkout:fixture', (_) async => true),
        throwsA(isA<SolutionError>()));
    vault.failCompletion = false;
    await session.clear();
    await session.authenticate('fixture@example.com', 'fixture-password');
    expect(session.pendingMutations, contains('checkout:fixture'));
  });

  test('explicit logout cleans owned configuration even when the vault fails',
      () async {
    final vault = MemoryVault();
    final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault);
    await session.authenticate('fixture@example.com', 'fixture-password');
    var cleanup = false;
    session.onAccountChange = (next) async {
      cleanup = next == null;
    };
    vault.failWrites = true;
    await expectLater(session.clear(), throwsA(isA<SolutionError>()));
    expect(cleanup, isTrue);
    expect(session.authenticated, isFalse);
  });

  test('journal read failure cannot overwrite unknown operations during login',
      () async {
    final vault = ReadFailureVault()
      ..journal = jsonEncode({
        'fixture@example.com': ['order:create']
      });
    final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault);
    await session.restore(removeLegacyCredentials: false);
    await expectLater(
        session.authenticate('fixture@example.com', 'fixture-password'),
        throwsA(isA<SolutionError>()));
    expect(vault.journal, contains('order:create'));
    vault.failRead = false;
    await session.authenticate('fixture@example.com', 'fixture-password');
    expect(session.pendingMutations, contains('order:create'));
  });

  test('mutation context cannot send with a newer account token', () async {
    var posts = 0;
    final session =
        SolutionSession(SolutionApi(client: MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/orders')
        posts++;
      return accountResponse(request);
    })), MemoryVault());
    await session.authenticate('fixture@example.com', 'fixture-password');
    final old = MutationContext(session, session.generation);
    await session.clear();
    await session.authenticate('fixture@example.com', 'fixture-password');
    await expectLater(
        old.request('/api/v1/orders'), throwsA(isA<SolutionError>()));
    expect(posts, 0);
  });

  test('successful mutation with failed completion storage remains locked',
      () async {
    final vault = BlockingVault();
    final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault);
    await session.authenticate('fixture@example.com', 'fixture-password');
    vault.writes = 0;
    vault.failCompletion = true;
    var calls = 0;
    await expectLater(
        session.mutate('checkout:fixture', (_) async {
          calls++;
          return true;
        }),
        throwsA(isA<SolutionError>()
            .having((e) => e.outcomeUnknown, 'unknown outcome', true)));
    await expectLater(
        session.mutate('checkout:fixture', (_) async {
          calls++;
          return true;
        }),
        throwsA(isA<SolutionError>()));
    expect(calls, 1);
    expect(session.pendingMutations, contains('checkout:fixture'));
  });

  test('unknown journal survives explicit logout and same-account login',
      () async {
    final vault = MemoryVault();
    final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault);
    await session.authenticate('fixture@example.com', 'fixture-password');
    await expectLater(
        session.mutate('order:create', (_) async {
          throw const SolutionError('NETWORK_ERROR', outcomeUnknown: true);
        }),
        throwsA(isA<SolutionError>()));
    await session.clear();
    expect(vault.value, isNull);
    expect(vault.journal, contains('order:create'));
    await session.authenticate('fixture@example.com', 'fixture-password');
    expect(session.pendingMutations, contains('order:create'));
    await session.acknowledgeNewIntent('order:create', session.generation);
    expect(session.pendingMutations, isNot(contains('order:create')));
  });

  test('mutating sentinels are checked before releasing the lock', () async {
    final session = SolutionSession(
        SolutionApi(
            client: MockClient((r) async => r.url.path == '/api/v1/tickets'
                ? success({'created': false})
                : accountResponse(r))),
        MemoryVault());
    await session.authenticate('fixture@example.com', 'fixture-password');
    await expectLater(
        session.mutate(
            'ticket:create',
            (mutation) =>
                mutation.request('/api/v1/tickets', successField: 'created')),
        throwsA(isA<SolutionError>()));
    expect(session.pendingMutations, contains('ticket:create'));
  });

  test('slow response timeout aborts the network stream', () async {
    final client = AbortObservingClient();
    final api =
        SolutionApi(client: client, timeout: const Duration(milliseconds: 20));
    await expectLater(api.call('/api/v1/me'), throwsA(isA<SolutionError>()));
    await client.aborted.future;
  });

  test('logout triggers only the owned-profile cleanup callback', () async {
    final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        MemoryVault());
    final changes = <String?>[];
    session.onAccountChange = (next) async {
      changes.add(next);
    };
    await session.authenticate('fixture@example.com', 'fixture-password');
    await session.clear();
    expect(changes, ['fixture@example.com', null]);
  });

  test('subscription disables nested TLS bypass and remote DNS listeners', () {
    final prepared = object(jsonDecode(prepareSubscription('''proxies:
  - name: fixture
    type: ss
    server: node.invalid
    port: 443
    cipher: aes-128-gcm
    password: fixture
    plugin: v2ray-plugin
    plugin-opts: {tls: true, skip-cert-verify: true}
proxy-groups: [{name: Proxy, type: select, proxies: [fixture]}]
rules: [MATCH,Proxy]
dns: {enable: true, listen: '0.0.0.0:5353', nameserver: ['1.1.1.1']}
ntp: {enable: true, write-to-system: true}
tunnels: [{network: tcp, address: '0.0.0.0:443'}]
''')));
    expect(
        object(objects(prepared['proxies']).first['plugin-opts'])[
            'skip-cert-verify'],
        false);
    expect(object(prepared['dns'])['listen'], isNull);
    expect(prepared['ntp'], isNull);
    expect(prepared['tunnels'], isNull);
  });

  test('shell quoting keeps metacharacters literal in an elevated launch', () {
    const filename = "/tmp/a'b \$(touch /tmp/unwanted) `touch unwanted`";
    final script = elevatedMacCommand(filename, '1234|fixture');
    final command = jsonDecode(script.substring('do shell script '.length,
        script.length - ' with administrator privileges'.length)) as String;
    expect(
        command, 'exec ${shellQuote(filename)} ${shellQuote('1234|fixture')}');
    expect(() => elevatedMacCommand('/tmp/line\nbreak', 'fixture'),
        throwsArgumentError);
  });
}
