import 'dart:async';

import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'solution_test.dart' show MemoryVault, accountResponse, success, failure;

Map<String, Object> order(String status, {String id = 'order-1'}) => {
      'id': id,
      'status': status,
      'amountMinor': 100,
      'createdAt': '2026-01-01T00:00:00Z',
    };

Future<void> unknown(SolutionSession session, String key) => expectLater(
      session.mutate(key, (_) async {
        throw const SolutionError('NETWORK_ERROR', outcomeUnknown: true);
      }),
      throwsA(isA<SolutionError>()),
    );

Future<SolutionSession> loggedIn(
    Future<http.Response> Function(http.Request) handler,
    {MemoryVault? vault}) async {
  final session = SolutionSession(
      SolutionApi(client: MockClient(handler)), vault ?? MemoryVault());
  await session.authenticate('fixture@example.com', 'fixture-password');
  addTearDown(session.api.close);
  return session;
}

class TokenWriteFailureVault extends MemoryVault {
  bool failToken = false;
  Completer<void>? tokenBlock;
  final tokenEntered = Completer<void>();
  @override
  Future<void> write(String? value) async {
    if (failToken) {
      if (!tokenEntered.isCompleted) tokenEntered.complete();
      await tokenBlock?.future;
      throw StateError('token write failed after journal write');
    }
    await super.write(value);
  }
}

void main() {
  for (final kind in ['order', 'ticket']) {
    test(
        '$kind terminal journal success / Token write failure keeps durable protection',
        () async {
      final vault = TokenWriteFailureVault();
      final session = await loggedIn((r) async {
        if (r.url.path == '/api/v1/orders/order-1') {
          return success(order('completed'));
        }
        if (r.url.path == '/api/v1/tickets/1') {
          return success({'id': '1', 'status': 'closed'});
        }
        return accountResponse(r);
      }, vault: vault);
      final key = kind == 'order' ? 'checkout:order-1' : 'ticket:close:1';
      await unknown(session, key);
      vault.failToken = true;
      await expectLater(
          kind == 'order'
              ? session.readOrder('order-1', session.generation)
              : session.readTicket('1', session.generation),
          throwsA(isA<SolutionError>()));
      expect(session.pendingMutations, contains(key));
      vault.failToken = false;
      final restored = SolutionSession(session.api, vault);
      await restored.restore(removeLegacyCredentials: false);
      expect(restored.pendingMutations, contains(key));
    });
    test(
        '$kind terminal storage blocked, logout then failure preserves the old journal',
        () async {
      final vault = TokenWriteFailureVault();
      final session = await loggedIn((r) async {
        if (r.url.path == '/api/v1/orders/order-1') {
          return success(order('completed'));
        }
        if (r.url.path == '/api/v1/tickets/1') {
          return success({'id': '1', 'status': 'closed'});
        }
        return accountResponse(r);
      }, vault: vault);
      final key = kind == 'order' ? 'checkout:order-1' : 'ticket:close:1';
      await unknown(session, key);
      vault.failToken = true;
      vault.tokenBlock = Completer<void>();
      final read = kind == 'order'
          ? session.readOrder('order-1', session.generation)
          : session.readTicket('1', session.generation);
      final assertion = expectLater(read, throwsA(isA<SolutionError>()));
      await vault.tokenEntered.future;
      final logout = session.clear();
      vault.failToken = false;
      vault.tokenBlock!.complete();
      await assertion;
      await logout;
      await session.authenticate('fixture@example.com', 'fixture-password');
      expect(session.pendingMutations, contains(key));
    });
  }
  for (final first in ['checkout', 'cancel']) {
    test('unknown $first locks both operations on the same order', () async {
      final session = await loggedIn((r) async => accountResponse(r));
      await unknown(session, '$first:order-1');
      var attempts = 0;
      final other = first == 'checkout' ? 'cancel' : 'checkout';
      await expectLater(
          session.mutate('$other:order-1', (_) async => attempts++),
          throwsA(isA<SolutionError>()));
      expect(attempts, 0);
      await session.mutate('$other:order-2', (_) async => true);
      expect(session.pendingMutations, contains('$first:order-1'));
    });
  }
  for (final status in [
    'pending',
    'processing',
    'completed',
    'cancelled',
    'adjusted'
  ]) {
    test('$status order readback releases only terminal locks without POST',
        () async {
      var posts = 0;
      final session = await loggedIn((r) async {
        if (r.url.path == '/api/v1/orders/order-1') {
          if (r.method != 'GET') posts++;
          return success(order(status));
        }
        return accountResponse(r);
      });
      await unknown(session, 'checkout:order-1');
      await session.readOrder('order-1', session.generation);
      expect(posts, 0);
      expect(session.orderOperationPending('order-1'),
          status == 'pending' || status == 'processing');
      await session.clear();
      await session.authenticate('fixture@example.com', 'fixture-password');
      expect(session.orderOperationPending('order-1'),
          status == 'pending' || status == 'processing');
    });
  }
  test('wrong order identity and failed completion storage keep the protection',
      () async {
    var wrongId = true;
    final vault = MemoryVault();
    final session = await loggedIn(
        (r) async => r.url.path == '/api/v1/orders/order-1'
            ? success(order('completed', id: wrongId ? 'other' : 'order-1'))
            : accountResponse(r),
        vault: vault);
    await unknown(session, 'cancel:order-1');
    await expectLater(session.readOrder('order-1', session.generation),
        throwsA(isA<SolutionError>()));
    wrongId = false;
    vault.failWrites = true;
    await expectLater(session.readOrder('order-1', session.generation),
        throwsA(isA<SolutionError>()));
    expect(session.orderOperationPending('order-1'), true);
    vault.failWrites = false;
    await session.readOrder('order-1', session.generation);
    expect(session.orderOperationPending('order-1'), false);
  });
  test('late old-account order response cannot clear new-account journal',
      () async {
    final waiting = Completer<http.Response>();
    final session = await loggedIn((r) async =>
        r.url.path == '/api/v1/orders/order-1'
            ? await waiting.future
            : accountResponse(r));
    await unknown(session, 'checkout:order-1');
    final read = session.readOrder('order-1', session.generation);
    final assertion = expectLater(read, throwsA(isA<SolutionError>()));
    await Future<void>.delayed(Duration.zero);
    await session.clear();
    await session.authenticate('fixture@example.com', 'fixture-password');
    waiting.complete(success(order('completed')));
    await assertion;
    expect(session.orderOperationPending('order-1'), true);
  });
  for (final status in ['open', 'closed', 'unknown']) {
    test(
        '$status ticket readback handles unknown close without automatic resend',
        () async {
      var posts = 0;
      final session = await loggedIn((r) async {
        if (r.url.path.startsWith('/api/v1/tickets/1')) {
          if (r.method == 'POST') posts++;
          return success({'id': '1', 'status': status});
        }
        return accountResponse(r);
      });
      await unknown(session, 'ticket:close:1');
      if (status == 'unknown') {
        await expectLater(session.readTicket('1', session.generation),
            throwsA(isA<SolutionError>()));
      } else {
        await session.readTicket('1', session.generation);
      }
      expect(posts, 0);
      expect(session.pendingMutations.contains('ticket:close:1'),
          status != 'closed');
    });
  }
  test('explicit close recovery rereads and is single-flight, success unlocks',
      () async {
    final read = Completer<http.Response>();
    var posts = 0;
    final session = await loggedIn((r) async {
      if (r.url.path == '/api/v1/tickets/1') return read.future;
      if (r.url.path == '/api/v1/tickets/1/close') {
        posts++;
        return success({'closed': true});
      }
      return accountResponse(r);
    });
    await unknown(session, 'ticket:close:1');
    final retry = session.retryTicketClose('1', session.generation);
    await expectLater(session.retryTicketClose('1', session.generation),
        throwsA(isA<SolutionError>()));
    expect(posts, 0);
    read.complete(success({'id': '1', 'status': 'open'}));
    await retry;
    expect(posts, 1);
    expect(session.pendingMutations, isEmpty);
  });
  for (final mode in [
    'closed',
    'wrong-id',
    'offline',
    'switched',
    'prewrite-failure',
    'postwrite-failure',
    'post-unknown',
    'post-rejected'
  ]) {
    test('close recovery $mode preserves or clears journal safely', () async {
      final read = Completer<http.Response>();
      final vault = MemoryVault();
      var posts = 0;
      final session = await loggedIn((r) async {
        if (r.url.path == '/api/v1/tickets/1') return read.future;
        if (r.url.path.endsWith('/close')) {
          posts++;
          if (mode == 'postwrite-failure') vault.failWrites = true;
          if (mode == 'post-unknown') {
            throw http.ClientException('lost response');
          }
          if (mode == 'post-rejected') return failure('INVALID_REQUEST', 400);
          return success({'closed': true});
        }
        return accountResponse(r);
      }, vault: vault);
      await unknown(session, 'ticket:close:1');
      final retry = session.retryTicketClose('1', session.generation);
      final assertion = mode == 'closed'
          ? expectLater(retry, completes)
          : expectLater(retry, throwsA(isA<SolutionError>()));
      await Future<void>.delayed(Duration.zero);
      if (mode == 'switched') {
        await session.clear();
        await session.authenticate('fixture@example.com', 'fixture-password');
      }
      if (mode == 'prewrite-failure') vault.failWrites = true;
      read.complete(mode == 'offline'
          ? failure('UPSTREAM_ERROR', 503)
          : success({
              'id': mode == 'wrong-id' ? '2' : '1',
              'status': mode == 'closed' ? 'closed' : 'open',
            }));
      await assertion;
      expect(posts, mode.startsWith('post') ? 1 : 0);
      expect(session.pendingMutations.contains('ticket:close:1'),
          mode != 'closed');
    });
  }
}
