import 'dart:async';
import 'package:fl_clash/solution/api.dart';
import 'package:fl_clash/solution/session.dart';
import 'package:fl_clash/solution/community_pages.dart';
import 'package:fl_clash/solution/shop_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'solution_test.dart' show MemoryVault, accountResponse, success;
import 'solution_recovery_test.dart' show unknown, order;

void main() {
  for (final mode in [
    'already-closed',
    'explicit-close',
    'abandoned',
    'dispose-read',
    'switch-read'
  ]) {
    testWidgets(
        'ticket recovery $mode refreshes page safely with no automatic POST',
        (tester) async {
      var reads = 0, posts = 0;
      var closed = false;
      final blocked = Completer<http.Response>();
      final api = SolutionApi(client: MockClient((r) async {
        if (r.url.path == '/api/v1/tickets/1') {
          reads++;
          if (reads == 2 && mode.endsWith('-read')) return blocked.future;
          if (reads == 2 && mode == 'already-closed') closed = true;
          return success({
            'id': '1',
            'status': closed ? 'closed' : 'open',
            'subject': 'Fixture ticket',
            'messages': []
          });
        }
        if (r.url.path.endsWith('/close')) {
          posts++;
          closed = true;
          return success({'closed': true});
        }
        return accountResponse(r);
      }));
      addTearDown(api.close);
      final session = SolutionSession(api, MemoryVault());
      await session.authenticate('fixture@example.com', 'fixture-password');
      await unknown(session, 'ticket:close:1');
      await tester.pumpWidget(ProviderScope(
          overrides: [solutionSessionProvider.overrideWith((_) => session)],
          child: MaterialApp(
              home: TicketPage(id: '1', generation: session.generation))));
      await tester.pumpAndSettle();
      expect(posts, 0);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '关闭工单'))
              .onPressed,
          isNull);
      await tester.ensureVisible(find.text('核验并恢复关闭工单'));
      await tester.tap(find.text('核验并恢复关闭工单'));
      await tester.pumpAndSettle();
      if (mode == 'explicit-close' || mode == 'abandoned') {
        expect(posts, 0);
        await tester.tap(find.text(mode == 'abandoned' ? '返回' : '确认重新关闭'));
        await tester.pumpAndSettle();
      }
      if (mode == 'dispose-read') {
        await tester.pumpWidget(const SizedBox.shrink());
        blocked.complete(success({'id': '1', 'status': 'open'}));
        await tester.pumpAndSettle();
      }
      if (mode == 'switch-read') {
        await session.clear();
        await session.authenticate('fixture@example.com', 'fixture-password');
        blocked.complete(success({'id': '1', 'status': 'open'}));
        await tester.pumpAndSettle();
      }
      if (mode == 'already-closed' || mode == 'explicit-close') {
        expect(session.pendingMutations, isEmpty);
        expect(find.text('关闭工单'), findsNothing);
        expect(find.text('回复工单'), findsNothing);
        expect(find.text('核验并恢复关闭工单'), findsNothing);
      } else {
        expect(session.pendingMutations, contains('ticket:close:1'));
      }
      expect(posts, mode == 'explicit-close' ? 1 : 0);
      expect(tester.takeException(), isNull);
    });
  }
  for (final key in ['checkout:order-1', 'cancel:order-1']) {
    testWidgets('$key unknown provides support and locks both order buttons',
        (tester) async {
      final api = SolutionApi(
          client: MockClient((r) async => r.url.path == '/api/v1/orders/order-1'
              ? success(order('pending'))
              : accountResponse(r)));
      addTearDown(api.close);
      final session = SolutionSession(api, MemoryVault());
      await session.authenticate('fixture@example.com', 'fixture-password');
      await unknown(session, key);
      await tester.pumpWidget(ProviderScope(
          overrides: [solutionSessionProvider.overrideWith((_) => session)],
          child: MaterialApp(
              home: OrderPage(id: 'order-1', generation: session.generation))));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, '选择方式并付款'))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '取消订单'))
              .onPressed,
          isNull);
      expect(find.text('联系客服核查订单'), findsOneWidget);
      await tester.tap(find.text('刷新支付结果'));
      await tester.pumpAndSettle();
      expect(session.orderOperationPending('order-1'), true);
    });
  }
}
