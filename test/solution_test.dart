import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/configuration.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryVault implements SessionVault {
  String? value;
  String? journal;
  @override
  Future<String?> readJournal() async => journal;
  @override
  Future<void> writeJournal(String next) async {
    if (failWrites) throw StateError('vault unavailable');
    journal = next;
  }

  bool failWrites = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? next) async {
    if (failWrites) throw StateError('vault unavailable');
    value = next;
  }
}

http.Response success(Object? data) => http.Response(
      jsonEncode({'ok': true, 'data': data, 'requestId': 'fixture'}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
http.Response failure(String code, int status) => http.Response(
      jsonEncode({
        'ok': false,
        'error': {'code': code},
      }),
      status,
    );
http.Response accountResponse(http.Request request) =>
    switch (request.url.path) {
      '/api/v1/auth/login' => success({
          'accessToken': 'fixture-token',
          'tokenType': 'Bearer',
        }),
      '/api/v1/me' => success({
          'email': 'fixture@example.com',
          'status': 'active',
          'expiresAt': null,
        }),
      '/api/v1/wallet' => success({'balanceMinor': 12345}),
      '/api/v1/config/account' => success({
          'currency': 'CNY',
          'currencySymbol': '¥',
        }),
      '/api/v1/subscription/overview' => success({
          'product': null,
          'expiresAt': null,
          'traffic': {
            'uploadedBytes': 2,
            'downloadedBytes': 3,
            'allowanceBytes': 100,
          },
        }),
      _ => success({}),
    };

void main() {
  group('Solution HTTPS boundary', () {
    for (final url in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com/api',
      'https://example.com?key=value',
      'https://example.com#fragment',
    ]) {
      test('rejects an untrusted API origin $url', () {
        expect(() => SolutionApi(baseUrl: url), throwsA(isA<SolutionError>()));
      });
    }
    test('preserves opaque authentication and minor units', () async {
      final api = SolutionApi(
        client: MockClient((request) async {
          expect(request.url.toString(), '$solutionOrigin/api/v1/wallet');
          expect(request.headers['Authorization'], 'Bearer fixture-token');
          expect(request.followRedirects, isFalse);
          return success({'balanceMinor': 12345});
        }),
      );
      final wallet = object(
        await api.call('/api/v1/wallet', token: 'fixture-token'),
      );
      expect(wallet['balanceMinor'], 12345);
    });
    test(
      'subscription carries the negotiated UA without account credentials',
      () async {
        final api = SolutionApi(
          client: MockClient((request) async {
            expect(request.headers['Authorization'], isNull);
            expect(request.headers['Cookie'], isNull);
            expect(request.headers['User-Agent'], startsWith('Clash.Meta/'));
            expect(request.followRedirects, isFalse);
            return http.Response('proxies: []', 200);
          }),
        );
        expect(
          utf8.decode(await api.download('$solutionOrigin/token-fixture')),
          'proxies: []',
        );
      },
    );
    for (final url in [
      'https://foreign.example/token',
      'http://cc-solution-stg.482658.xyz/token',
      '/relative',
      'https://user:pass@cc-solution-stg.482658.xyz/token',
    ]) {
      test('rejects subscription destination $url before sending', () async {
        var calls = 0;
        final api = SolutionApi(
          client: MockClient((_) async {
            calls++;
            return success({});
          }),
        );
        await expectLater(api.download(url), throwsA(isA<SolutionError>()));
        expect(calls, 0);
      });
    }
    test('does not follow redirect or repeat a lost POST', () async {
      var calls = 0;
      final api = SolutionApi(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            '',
            302,
            headers: {'location': 'https://foreign.example'},
          );
        }),
      );
      await expectLater(
        api.call('/api/v1/orders', method: 'POST', body: {}),
        throwsA(
          isA<SolutionError>().having(
            (e) => e.outcomeUnknown,
            'unknown outcome',
            true,
          ),
        ),
      );
      expect(calls, 1);
    });
    test('bounds responses and does not expose an error body', () async {
      final api = SolutionApi(
        client: MockClient((_) async => http.Response('secret' * 400000, 200)),
      );
      await expectLater(api.call('/api/v1/me'), throwsA(isA<SolutionError>()));
      expect(
        const SolutionError('NETWORK_ERROR').toString(),
        isNot(contains('secret')),
      );
    });
    test('finished action does not manufacture completed order status', () {
      final action = CheckoutAction({'type': 'finished'});
      final order = SolutionOrder({
        'id': 'fixture',
        'status': 'pending',
        'amountMinor': 123,
        'createdAt': '2026-01-01T00:00:00Z',
      });
      expect(action.type, 'finished');
      expect(order.terminal, isFalse);
      expect(order.status, OrderStatus.pending);
    });
    test('unknown order states and unsafe checkout URLs fail closed', () {
      expect(
        () => SolutionOrder({
          'id': 'fixture',
          'status': 'paid',
          'amountMinor': 123,
          'createdAt': '2026-01-01T00:00:00Z',
        }),
        throwsA(isA<SolutionError>()),
      );
      for (final uri in [
        'javascript:alert(1)',
        'http://pay.example',
        'https://user:pass@pay.example',
      ]) {
        expect(
          () => CheckoutAction({'type': 'redirect', 'target': uri}),
          throwsA(isA<SolutionError>()),
        );
      }
      expect(
        CheckoutAction({'type': 'qrcode', 'data': 'alipay://fixture'}).payload,
        'alipay://fixture',
      );
    });
  });

  group('Session and non-idempotent operations', () {
    test('login stores the session without saving the password', () async {
      final vault = MemoryVault();
      final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault,
      );
      await session.authenticate('fixture@example.com', 'fixture-password');
      expect(session.authenticated, isTrue);
      expect(session.balanceMinor, 12345);
      expect(vault.value, contains('fixture-token'));
      expect(vault.value, isNot(contains('fixture-password')));
      await session.clear();
      expect(vault.value, isNull);
      expect(session.account, isNull);
    });
    test('secure-store failure prevents authenticated persistence', () async {
      final vault = MemoryVault()..failWrites = true;
      final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault,
      );
      await expectLater(
        session.authenticate('fixture@example.com', 'fixture-password'),
        throwsA(isA<SolutionError>()),
      );
      expect(session.authenticated, isFalse);
    });
    for (final status in [502, 504]) {
      test(
        'HTTP $status preserves session and last account information',
        () async {
          var offline = false;
          final vault = MemoryVault();
          final session = SolutionSession(
            SolutionApi(
              client: MockClient(
                (r) async => offline
                    ? failure('UPSTREAM_TIMEOUT', status)
                    : accountResponse(r),
              ),
            ),
            vault,
          );
          await session.authenticate('fixture@example.com', 'fixture-password');
          offline = true;
          await session.refreshAccount();
          expect(session.authenticated, isTrue);
          expect(session.account?['email'], 'fixture@example.com');
          expect(session.balanceMinor, 12345);
        },
      );
    }
    test(
      'a confirmed 401 clears session instead of retrying authentication',
      () async {
        var expired = false;
        final vault = MemoryVault();
        final session = SolutionSession(
          SolutionApi(
            client: MockClient(
              (r) async =>
                  expired ? failure('AUTH_FAILED', 401) : accountResponse(r),
            ),
          ),
          vault,
        );
        await session.authenticate('fixture@example.com', 'fixture-password');
        expired = true;
        await session.refreshAccount();
        expect(session.authenticated, isFalse);
        expect(vault.value, isNull);
      },
    );
    test(
      'a response arriving after logout cannot restore old user data',
      () async {
        final delayed = Completer<http.Response>();
        var delay = false;
        final session = SolutionSession(
          SolutionApi(
            client: MockClient(
              (r) async => delay && r.url.path == '/api/v1/me'
                  ? await delayed.future
                  : accountResponse(r),
            ),
          ),
          MemoryVault(),
        );
        await session.authenticate('fixture@example.com', 'fixture-password');
        delay = true;
        final refresh = session.refreshAccount();
        await Future<void>.delayed(Duration.zero);
        await session.clear();
        delayed.complete(
          success({
            'email': 'old@example.com',
            'status': 'active',
            'expiresAt': null,
          }),
        );
        await refresh;
        expect(session.account, isNull);
        expect(session.authenticated, isFalse);
      },
    );
    test(
      'ambiguous mutation is durable and a repeat never reaches the API',
      () async {
        final vault = MemoryVault();
        final session = SolutionSession(
          SolutionApi(client: MockClient((r) async => accountResponse(r))),
          vault,
        );
        await session.authenticate('fixture@example.com', 'fixture-password');
        var calls = 0;
        Future<void> action(MutationContext _) async {
          calls++;
          throw const SolutionError('NETWORK_ERROR', outcomeUnknown: true);
        }

        await expectLater(
          session.mutate('order:create', action),
          throwsA(isA<SolutionError>()),
        );
        await expectLater(
          session.mutate('order:create', action),
          throwsA(isA<SolutionError>()),
        );
        expect(calls, 1);
        final restored = SolutionSession(
          SolutionApi(client: MockClient((r) async => accountResponse(r))),
          vault,
        );
        await restored.restore(removeLegacyCredentials: false);
        expect(restored.pendingMutations, contains('order:create'));
      },
    );
    test('malformed mutation success remains locked', () async {
      final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        MemoryVault(),
      );
      await session.authenticate('fixture@example.com', 'fixture-password');
      await expectLater(
        session.mutate('order:create', (_) async => string(null)),
        throwsA(isA<SolutionError>()),
      );
      expect(session.pendingMutations, contains('order:create'));
    });
    test(
      'definitive validation failure permits a corrected new request',
      () async {
        final session = SolutionSession(
          SolutionApi(client: MockClient((r) async => accountResponse(r))),
          MemoryVault(),
        );
        await session.authenticate('fixture@example.com', 'fixture-password');
        await expectLater(
          session.mutate('order:create', (_) async {
            throw const SolutionError('VALIDATION_ERROR');
          }),
          throwsA(isA<SolutionError>()),
        );
        expect(session.pendingMutations, isNot(contains('order:create')));
      },
    );
    test('vault failure prevents an outbound mutation', () async {
      final vault = MemoryVault();
      final session = SolutionSession(
        SolutionApi(client: MockClient((r) async => accountResponse(r))),
        vault,
      );
      await session.authenticate('fixture@example.com', 'fixture-password');
      vault.failWrites = true;
      var called = false;
      await expectLater(
        session.mutate('checkout:fixture', (_) async {
          called = true;
        }),
        throwsA(isA<SolutionError>()),
      );
      expect(called, isFalse);
    });
  });

  group('Subscription safety', () {
    const valid = '''proxies:
  - {name: fixture, type: ss, server: node.invalid, port: 443, cipher: aes-128-gcm, password: fixture}
proxy-groups:
  - {name: Proxy, type: select, proxies: [fixture]}
rules: [MATCH,Proxy]
external-controller: 0.0.0.0:9090
allow-lan: true
''';
    test(
      'creates automatic/fallback groups and closes remote control listeners',
      () {
        final data = object(jsonDecode(prepareSubscription(valid)));
        expect(data['external-controller'], isNull);
        expect(data['allow-lan'], false);
        expect(data['bind-address'], '127.0.0.1');
        expect(
          objects(data['proxy-groups']).map((g) => g['type']),
          containsAll(['url-test', 'fallback']),
        );
      },
    );
    test(
      'remote providers and duplicate node names cannot become local files',
      () {
        expect(
          () => prepareSubscription('$valid\nproxy-providers: {}'),
          throwsA(isA<SolutionError>()),
        );
        expect(
          () => prepareSubscription(
            valid.replaceFirst(
              'proxy-groups:',
              '  - {name: fixture, type: direct}\nproxy-groups:',
            ),
          ),
          throwsA(isA<SolutionError>()),
        );
      },
    );
    test('never accepts a subscription TLS verification bypass', () {
      final data = object(
        jsonDecode(
          prepareSubscription(
            valid.replaceFirst(
              'password: fixture',
              'password: fixture, skip-cert-verify: true',
            ),
          ),
        ),
      );
      expect(objects(data['proxies']).first['skip-cert-verify'], false);
    });
    for (final input in [
      '',
      '<html>login</html>',
      'c3M6Ly9maXh0dXJl',
      'proxies: null',
      'proxies: [',
      'proxies: []\nproxy-groups: []',
      '!!dart/object: [fixture]',
    ]) {
      test('rejects malformed subscription ${input.length} bytes', () {
        expect(() => prepareSubscription(input), throwsA(anything));
      });
    }
  });
}
