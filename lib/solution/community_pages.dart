import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'session.dart';
import 'widgets.dart';

Future<List<String>?> messageDialog(
  BuildContext context, {
  bool subject = false,
}) async {
  final title = TextEditingController();
  final message = TextEditingController();
  try {
    return await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(subject ? '创建工单' : '回复工单'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (subject)
                  TextField(
                    controller: title,
                    maxLength: 255,
                    decoration: const InputDecoration(labelText: '主题'),
                  ),
                TextField(
                  controller: message,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '问题描述'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (message.text.trim().isEmpty ||
                  subject && title.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(context, [title.text.trim(), message.text.trim()]);
            },
            child: const Text('提交'),
          ),
        ],
      ),
    );
  } finally {
    title.dispose();
    message.dispose();
  }
}

class SolutionSupportPage extends ConsumerWidget {
  const SolutionSupportPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => AccountGate(
        child: RemotePanel(
          load: () =>
              ref.read(solutionSessionProvider).request('/api/v1/tickets'),
          builder: (data, refresh) {
            final session = ref.read(solutionSessionProvider);
            final tickets = objects(object(data)['tickets']);
            return BusinessBody(
              children: [
                Text('客服工单', style: Theme.of(context).textTheme.titleLarge),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('创建工单'),
                      onPressed:
                          session.pendingMutations.contains('ticket:create')
                              ? null
                              : () => uiAction(context, () async {
                                    final expected = session.generation;
                                    final form = await messageDialog(
                                      context,
                                      subject: true,
                                    );
                                    if (form == null ||
                                        expected != session.generation) {
                                      return;
                                    }
                                    await session.mutate(
                                      'ticket:create',
                                      (mutation) => mutation.request(
                                        '/api/v1/tickets',
                                        method: 'POST',
                                        successField: 'created',
                                        body: {
                                          'subject': form[0],
                                          'priority': 'normal',
                                          'message': form[1],
                                        },
                                      ),
                                    );
                                    refresh();
                                  }, success: '工单已提交'),
                    ),
                    OutlinedButton(
                        onPressed: refresh, child: const Text('刷新工单')),
                  ],
                ),
                if (session.pendingMutations.contains('ticket:create'))
                  const Text('上次提交结果尚未确认，请核对工单列表，勿重复发送。'),
                if (session.pendingMutations.contains('ticket:create'))
                  PendingReviewButton(
                    operationKey: 'ticket:create',
                    generation: session.generation,
                  ),
                if (tickets.isEmpty) const Text('暂无工单'),
                for (final ticket in tickets)
                  ListTile(
                    title: Text(string(ticket['subject'])),
                    subtitle: Text(ticket['status'] == 'open' ? '处理中' : '已关闭'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TicketPage(
                          id: string(ticket['id']),
                          generation: session.generation,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
}

class TicketPage extends ConsumerWidget {
  final String id;
  final int generation;
  const TicketPage({super.key, required this.id, required this.generation});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(solutionSessionProvider);
    if (session.generation != generation) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('账户已切换，请返回工单列表。')),
      );
    }
    final path = '/api/v1/tickets/${Uri.encodeComponent(id)}';
    return Scaffold(
      appBar: AppBar(title: const Text('工单详情')),
      body: RemotePanel(
        load: () => session.request(path),
        builder: (data, refresh) {
          final ticket = object(data);
          return BusinessBody(
            children: [
              Text(
                string(ticket['subject']),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final message in objects(ticket['messages']))
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(message['fromMe'] == true ? '我' : '客服'),
                        const SizedBox(height: 8),
                        SelectableText(string(message['content'])),
                      ],
                    ),
                  ),
                ),
              OutlinedButton(onPressed: refresh, child: const Text('刷新回复')),
              if (session.pendingMutations.contains('ticket:reply:$id'))
                PendingReviewButton(
                  operationKey: 'ticket:reply:$id',
                  generation: generation,
                ),
              if (ticket['status'] == 'open') ...[
                FilledButton(
                  onPressed:
                      session.pendingMutations.contains('ticket:reply:$id')
                          ? null
                          : () => uiAction(context, () async {
                                final form = await messageDialog(context);
                                if (form == null ||
                                    session.generation != generation) {
                                  return;
                                }
                                await session.mutate(
                                  'ticket:reply:$id',
                                  (mutation) => mutation.request(
                                    '$path/reply',
                                    method: 'POST',
                                    successField: 'replied',
                                    body: {'message': form[1]},
                                  ),
                                );
                                refresh();
                              }),
                  child: const Text('回复工单'),
                ),
                TextButton(
                  onPressed: () => uiAction(context, () async {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('关闭此工单？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('返回'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('关闭工单'),
                          ),
                        ],
                      ),
                    );
                    if (yes != true || session.generation != generation) return;
                    await session.mutate(
                      'ticket:close:$id',
                      (mutation) => mutation.request(
                        '$path/close',
                        method: 'POST',
                        successField: 'closed',
                      ),
                    );
                    refresh();
                  }),
                  child: const Text('关闭工单'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class SolutionReferralsPage extends ConsumerWidget {
  const SolutionReferralsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => AccountGate(
        child: RemotePanel(
          load: () =>
              ref.read(solutionSessionProvider).request('/api/v1/referrals'),
          builder: (data, refresh) {
            final value = object(data);
            final stats = object(value['stats']);
            final session = ref.read(solutionSessionProvider);
            return BusinessBody(
              children: [
                Text('邀请与返佣', style: Theme.of(context).textTheme.titleLarge),
                if (session.pendingMutations.contains('referral:create'))
                  PendingReviewButton(
                    operationKey: 'referral:create',
                    generation: session.generation,
                  ),
                Text('已邀请 ${integer(stats['registeredUsers'])} 人'),
                Text(
                  '累计佣金 ${money(integer(stats['earnedCommissionMinor']), session.currencySymbol)}',
                ),
                Text(
                  '待确认佣金 ${money(integer(stats['pendingCommissionMinor']), session.currencySymbol)}',
                ),
                Text(
                  '可用佣金 ${money(integer(stats['availableCommissionMinor']), session.currencySymbol)}',
                ),
                for (final code in objects(value['codes']))
                  ListTile(
                    title: SelectableText(string(code['code'])),
                    subtitle: const Text('邀请码'),
                    trailing: IconButton(
                      tooltip: '复制邀请码',
                      icon: const Icon(Icons.copy),
                      onPressed: () => uiAction(context, () async {
                        await Clipboard.setData(
                          ClipboardData(text: string(code['code'])),
                        );
                      }, success: '邀请码已复制'),
                    ),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed:
                          session.pendingMutations.contains('referral:create')
                              ? null
                              : () => uiAction(context, () async {
                                    await session.mutate(
                                      'referral:create',
                                      (mutation) => mutation.request(
                                        '/api/v1/referrals/codes',
                                        method: 'POST',
                                        successField: 'created',
                                      ),
                                    );
                                    refresh();
                                  }),
                      child: const Text('生成邀请码'),
                    ),
                    OutlinedButton(onPressed: refresh, child: const Text('刷新')),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text('返佣记录')),
                            body: AccountGate(
                              child: RemotePanel(
                                load: () => session.request(
                                  '/api/v1/referrals/commissions?page=1&pageSize=100',
                                ),
                                builder: (history, reload) => BusinessBody(
                                  children: [
                                    for (final row in objects(
                                      object(history)['items'],
                                    ))
                                      ListTile(
                                        title: Text(
                                          money(
                                            integer(
                                                row['commissionAmountMinor']),
                                            session.currencySymbol,
                                          ),
                                        ),
                                        subtitle:
                                            Text(string(row['createdAt'])),
                                      ),
                                    Text(
                                      '共 ${object(history)['total']} 条记录，显示最近 100 条',
                                    ),
                                    OutlinedButton(
                                      onPressed: reload,
                                      child: const Text('刷新'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('查看返佣记录'),
                    ),
                  ],
                ),
                const Text('返佣资格、金额及结算状态以服务端记录为准。'),
              ],
            );
          },
        ),
      );
}
