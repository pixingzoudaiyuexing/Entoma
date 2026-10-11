import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:fl_clash/solution/shop_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'solution_test.dart' show MemoryVault, accountResponse, failure, success;

Map<String, Object> order(String status) => {
      'id': 'fixture-order',
      'status': status,
      'amountMinor': 12345,
      'createdAt': '2026-01-01T00:00:00Z',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var launches = <String>[];
  setUp(() {
    launches = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') {
          launches.add((call.arguments as Map)['url'] as String);
        }
        return true;
      },
    );
  });

  Future<SolutionSession> mount(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) handler,
  ) async {
    final api = SolutionApi(client: MockClient(handler));
    addTearDown(api.close);
    final session = SolutionSession(api, MemoryVault());
    await session.authenticate('fixture@example.com', 'fixture-password');
    await tester.pumpWidget(ProviderScope(
      overrides: [solutionSessionProvider.overrideWith((_) => session)],
      child: MaterialApp(
        home: OrderPage(id: 'fixture-order', generation: session.generation),
      ),
    ));
    await tester.pumpAndSettle();
    return session;
  }

  Future<void> choosePayment(WidgetTester tester) async {
    await tester.ensureVisible(find.text('选择方式并付款'));
    await tester.tap(find.text('选择方式并付款'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Fixture Pay'));
    await tester.pump();
    await tester.pump();
  }

  for (final type in ['qrcode', 'redirect', 'finished']) {
    testWidgets('$type uses authoritative status and stops after completion',
        (tester) async {
      var reads = 0;
      var checkouts = 0;
      var completed = false;
      await mount(tester, (r) async {
        if (r.url.path == '/api/v1/orders/fixture-order') {
          reads++;
          return success(order(completed ? 'completed' : 'pending'));
        }
        if (r.url.path == '/api/v1/billing/methods') {
          return success([
            {
              'id': '2',
              'name': 'Fixture Pay',
              'fee': {'percent': 2, 'fixedMinor': 50},
            },
          ]);
        }
        if (r.url.path.endsWith('/checkout')) {
          checkouts++;
          expect(r.body, '{"paymentMethodId":"2"}');
          return success({
            'type': type,
            if (type == 'redirect') 'target': 'https://pay.example/fixture',
            if (type == 'qrcode') 'data': 'alipay://fixture-opaque',
          });
        }
        return accountResponse(r);
      });
      expect(find.text('应付 123.45'), findsOneWidget);
      await choosePayment(tester);
      await tester.pumpAndSettle();
      expect(find.text('待付款'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      expect(checkouts, 1);
      expect(
          launches, type == 'redirect' ? ['https://pay.example/fixture'] : []);
      if (type == 'qrcode') {
        expect(find.byType(QrImageView), findsOneWidget);
      }
      completed = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('已完成'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('重新打开支付页面'), findsNothing);
      final stoppedAt = reads;
      await tester.pump(const Duration(seconds: 15));
      expect(reads, stoppedAt);
      expect(checkouts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final leave in ['dispose', 'logout']) {
    testWidgets('$leave during readback cannot open an old payment URL',
        (tester) async {
      final readback = Completer<http.Response>();
      var reads = 0;
      final session = await mount(tester, (r) async {
        if (r.url.path == '/api/v1/orders/fixture-order') {
          if (++reads == 2) return readback.future;
          return success(order('pending'));
        }
        if (r.url.path == '/api/v1/billing/methods') {
          return success([
            {
              'id': '2',
              'name': 'Fixture Pay',
              'fee': {'percent': 0, 'fixedMinor': 0},
            },
          ]);
        }
        if (r.url.path.endsWith('/checkout')) {
          return success({
            'type': 'redirect',
            'target': 'https://pay.example/old-account',
          });
        }
        return accountResponse(r);
      });
      await choosePayment(tester);
      expect(reads, 2);
      if (leave == 'dispose') {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        await session.clear();
        await tester.pump();
      }
      readback.complete(success(order('pending')));
      await tester.pumpAndSettle();
      expect(launches, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in ['created', 'coupon-rejected', 'lost-response']) {
    testWidgets('product order $outcome uses server amount and durable outcome',
        (tester) async {
      var creates = 0;
      final api = SolutionApi(client: MockClient((r) async {
        if (r.url.path == '/api/v1/products/7') {
          return success({
            'product': {
              'name': 'Fixture Plan',
              'dataAllowanceGb': 100,
              'prices': [
                {'billingPeriod': 'month', 'amountMinor': 2500}
              ],
            },
          });
        }
        if (r.url.path == '/api/v1/orders') {
          creates++;
          expect(r.method, 'POST');
          expect(jsonDecode(r.body), {
            'productId': '7',
            'billingPeriod': 'month',
            'promotionCode': 'FIXTURE',
          });
          return switch (outcome) {
            'created' => success({'id': 'fixture-order'}),
            'coupon-rejected' => failure('PROMOTION_INVALID', 422),
            _ => failure('UPSTREAM_TIMEOUT', 502),
          };
        }
        if (r.url.path == '/api/v1/orders/fixture-order') {
          return success(order('pending'));
        }
        return accountResponse(r);
      }));
      addTearDown(api.close);
      final vault = MemoryVault();
      final session = SolutionSession(api, vault);
      await session.authenticate('fixture@example.com', 'fixture-password');
      await tester.pumpWidget(ProviderScope(
        overrides: [solutionSessionProvider.overrideWith((_) => session)],
        child: MaterialApp(
            home: ProductPage(productId: '7', generation: session.generation)),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('月付'));
      await tester.pump();
      await tester.enterText(
          find.widgetWithText(TextField, '优惠码（可选）'), ' FIXTURE ');
      await tester.ensureVisible(find.text('创建订单并查看应付金额'));
      await tester.tap(find.text('创建订单并查看应付金额'));
      await tester.pumpAndSettle();
      expect(creates, 1);
      if (outcome == 'created') {
        expect(find.text('订单与付款'), findsOneWidget);
        expect(find.textContaining('123.45'), findsOneWidget);
        expect(session.pendingMutations, isEmpty);
      } else {
        final pending = outcome == 'lost-response';
        expect(session.pendingMutations.contains('order:create'), pending);
        if (pending) {
          expect(vault.journal, contains('order:create'));
          await tester.pump(const Duration(seconds: 30));
          expect(creates, 1);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
