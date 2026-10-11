import 'dart:convert';
import 'dart:async';

import 'package:fl_clash/solution/account_page.dart';
import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'solution_test.dart' show MemoryVault, accountResponse, failure, success;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('blocked native Keychain read fails closed and releases startup',
      () async {
    final blocked = Completer<dynamic>();
    var sends = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) => blocked.future,
    );
    addTearDown(() {
      blocked.complete(null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null);
    });
    final api = SolutionApi(client: MockClient((r) async {
      sends++;
      return accountResponse(r);
    }));
    addTearDown(api.close);
    final vault = NativeSessionVault(solutionOrigin,
        readTimeout: const Duration(milliseconds: 5));
    final session = SolutionSession(api, vault);
    await session.restore(removeLegacyCredentials: false);
    expect(session.initialized, isTrue);
    expect(session.authenticated, isFalse);
    expect(session.notice, contains('密钥存储'));
    expect(sends, 0);
  });
  for (final scenario in [
    '401',
    '502',
    'missing-token',
    'wrong-type',
    'me-401'
  ]) {
    test('failed login $scenario never persists credentials or retries',
        () async {
      var attempts = 0;
      final vault = MemoryVault();
      final api = SolutionApi(client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          attempts++;
          return switch (scenario) {
            '401' => failure('AUTH_FAILED', 401),
            '502' => failure('UPSTREAM_TIMEOUT', 502),
            'missing-token' => success({'tokenType': 'Bearer'}),
            'wrong-type' =>
              success({'accessToken': 'fixture', 'tokenType': 'Basic'}),
            _ => accountResponse(r),
          };
        }
        return failure('AUTH_REQUIRED', 401);
      }));
      addTearDown(api.close);
      final session = SolutionSession(api, vault);
      await expectLater(
          session.authenticate('fixture@example.com', 'fixture-password'),
          throwsA(isA<SolutionError>()));
      expect(session.authenticated, isFalse);
      expect(session.busy, isFalse);
      expect(session.notice, isNotNull);
      expect(vault.value, isNull);
      expect(attempts, 1);
    });
  }

  test('register sends canonical fields and stores only validated auth',
      () async {
    final vault = MemoryVault();
    final api = SolutionApi(client: MockClient((r) async {
      if (r.url.path.endsWith('/register')) {
        expect(jsonDecode(r.body), {
          'email': 'fixture@example.com',
          'password': 'fixture-password',
          'emailCode': '123456',
          'inviteCode': 'FIXTURE',
        });
        return success({'accessToken': 'fixture-token', 'tokenType': 'Bearer'});
      }
      return accountResponse(r);
    }));
    addTearDown(api.close);
    final session = SolutionSession(api, vault);
    await session.authenticate(' fixture@example.com ', 'fixture-password',
        register: true, emailCode: '123456', inviteCode: 'FIXTURE');
    expect(session.authenticated, isTrue);
    expect(vault.value, isNot(contains('fixture-password')));
    expect(vault.value, isNot(contains('123456')));
  });

  test(
      'secure restore refreshes business data and preserves account journal isolation',
      () async {
    final vault = MemoryVault()
      ..value =
          jsonEncode({'token': 'fixture-token', 'email': 'fixture@example.com'})
      ..journal = jsonEncode({
        'fixture@example.com': ['create-order'],
        'other@example.com': ['ticket-create'],
      });
    final api =
        SolutionApi(client: MockClient((r) async => accountResponse(r)));
    addTearDown(api.close);
    final session = SolutionSession(api, vault);
    await session.restore(removeLegacyCredentials: false);
    await session.refreshAccount();
    expect(session.authenticated, isTrue);
    expect(session.balanceMinor, 12345);
    expect(session.overview?['traffic']['allowanceBytes'], 100);
    expect(session.pendingMutations, {'create-order'});
    expect(vault.journal, contains('other@example.com'));
  });

  Future<void> mountAuth(WidgetTester tester,
      Future<http.Response> Function(http.Request) handler) async {
    final api = SolutionApi(client: MockClient(handler));
    addTearDown(api.close);
    final session = SolutionSession(api, MemoryVault())..initialized = true;
    await tester.pumpWidget(ProviderScope(
      overrides: [solutionSessionProvider.overrideWith((_) => session)],
      child: const MaterialApp(home: Scaffold(body: SolutionAccountPage())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('忘记密码'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, '邮箱'), 'fixture@example.com');
    await tester.enterText(
        find.widgetWithText(TextField, '新密码'), 'fixture-new-password');
    await tester.enterText(find.widgetWithText(TextField, '邮箱验证码'), '123456');
  }

  for (final outcome in ['success', 'false-marker', 'null-body']) {
    final positive = outcome == 'success';
    testWidgets('email/reset requires explicit success marker $outcome',
        (tester) async {
      var emailCodes = 0;
      var resets = 0;
      await mountAuth(tester, (r) async {
        if (r.url.path.endsWith('/email-code')) {
          emailCodes++;
          expect(jsonDecode(r.body),
              {'email': 'fixture@example.com', 'purpose': 'password-reset'});
          return success(outcome == 'null-body' ? null : {'sent': positive});
        }
        if (r.url.path.endsWith('/password/reset')) {
          resets++;
          expect(jsonDecode(r.body), {
            'email': 'fixture@example.com',
            'emailCode': '123456',
            'newPassword': 'fixture-new-password',
          });
          return success(outcome == 'null-body' ? null : {'reset': positive});
        }
        return success({
          'antiBot': {'enabled': false},
          'termsUrl': null
        });
      });
      await tester.ensureVisible(find.text('发送验证码'));
      await tester.tap(find.text('发送验证码'));
      await tester.pumpAndSettle();
      expect(emailCodes, 1);
      expect(
          find.text('验证码已发送，请查看邮箱'), positive ? findsOneWidget : findsNothing);
      await tester.ensureVisible(find.text('重置密码'));
      await tester.tap(find.text('重置密码'));
      await tester.pumpAndSettle();
      expect(resets, 1);
      expect(find.text('登录账户'), positive ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
