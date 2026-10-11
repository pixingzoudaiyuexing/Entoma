import 'dart:async';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'session.dart';
import 'subscription.dart';
import 'widgets.dart';

class SolutionAccountPage extends ConsumerStatefulWidget {
  const SolutionAccountPage({super.key});
  @override
  ConsumerState<SolutionAccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<SolutionAccountPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  final code = TextEditingController();
  final invite = TextEditingController();
  String mode = 'login';
  bool working = false;
  bool acceptedTerms = false;
  DateTime? codeSent;
  Map<String, dynamic>? onboarding;
  @override
  void initState() {
    super.initState();
    unawaited(_onboarding());
  }

  Future<void> _onboarding() async {
    try {
      final result = object(
        await ref
            .read(solutionSessionProvider)
            .api
            .call('/api/v1/config/onboarding'),
      );
      if (mounted) {
        setState(() {
          onboarding = result;
        });
      }
    } catch (_) {
      /* The local sign-in form remains usable offline. */
    }
  }

  @override
  void dispose() {
    email.dispose();
    password.clear();
    password.dispose();
    code.dispose();
    invite.dispose();
    super.dispose();
  }

  Future<void> act(Future<void> Function() task, {String? success}) async {
    if (working) return;
    setState(() {
      working = true;
    });
    await uiAction(context, task, success: success);
    if (mounted) {
      setState(() {
        working = false;
      });
    }
  }

  Future<void> submit() async {
    final session = ref.read(solutionSessionProvider);
    if (email.text.trim().isEmpty || password.text.length < 8) {
      throw const SolutionError('VALIDATION_ERROR');
    }
    if (mode == 'reset') {
      await session.api.call(
        '/api/v1/auth/password/reset',
        method: 'POST',
        body: {
          'email': email.text.trim(),
          'emailCode': code.text.trim(),
          'newPassword': password.text,
        },
      );
      password.clear();
      if (mounted) {
        setState(() {
          mode = 'login';
        });
      }
      return;
    }
    if (mode == 'register') {
      final config = onboarding ??
          object(await session.api.call('/api/v1/config/onboarding'));
      if (config['termsUrl'] != null && !acceptedTerms) {
        throw const SolutionError('VALIDATION_ERROR');
      }
      if (object(config['antiBot'])['enabled'] == true) {
        throw const SolutionError('CHALLENGE_REQUIRED');
      }
    }
    await session.authenticate(
      email.text,
      password.text,
      register: mode == 'register',
      emailCode: code.text.trim(),
      inviteCode: invite.text.trim(),
    );
    password.clear();
    // Subscription failure never rolls back an otherwise valid login.
    try {
      await ref.read(solutionSubscriptionProvider).refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已登录，订阅尚未刷新。可稍后重试，已有配置仍可使用。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(solutionSessionProvider);
    if (!session.authenticated) {
      return BusinessBody(
        children: [
          Text('Entoma', style: Theme.of(context).textTheme.headlineMedium),
          Text(
            mode == 'login'
                ? '登录账户'
                : mode == 'register'
                    ? '创建账户'
                    : '找回密码',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (session.notice != null) Text(session.notice!),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              labelText: '邮箱',
              border: OutlineInputBorder(),
            ),
          ),
          TextField(
            controller: password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            autofillHints: mode == 'login'
                ? const [AutofillHints.password]
                : const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: mode == 'reset' ? '新密码' : '密码',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) {
              if (!working) act(submit);
            },
          ),
          if (mode != 'login') ...[
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: '邮箱验证码'),
            ),
            OutlinedButton(
              onPressed: working
                  ? null
                  : () => act(() async {
                        if (codeSent != null &&
                            DateTime.now().difference(codeSent!).inSeconds <
                                60) {
                          return;
                        }
                        await session.api.call(
                          '/api/v1/auth/email-code',
                          method: 'POST',
                          body: {
                            'email': email.text.trim(),
                            'purpose': mode == 'register'
                                ? 'register'
                                : 'password-reset',
                          },
                        );
                        codeSent = DateTime.now();
                      }, success: '验证码已发送，请查看邮箱'),
              child: const Text('发送验证码'),
            ),
          ],
          if (mode == 'register')
            TextField(
              controller: invite,
              decoration: const InputDecoration(labelText: '邀请码（如需要）'),
            ),
          if (mode == 'register' && onboarding?['termsUrl'] != null) ...[
            TextButton(
              onPressed: () => uiAction(context, () async {
                final url = Uri.parse(string(onboarding!['termsUrl']));
                if (url.scheme != 'https' || url.userInfo.isNotEmpty) {
                  throw const SolutionError('INVALID_RESPONSE');
                }
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }),
              child: const Text('阅读服务条款'),
            ),
            CheckboxListTile(
              value: acceptedTerms,
              onChanged: working
                  ? null
                  : (v) => setState(() {
                        acceptedTerms = v == true;
                      }),
              title: const Text('我已阅读并同意服务条款'),
            ),
          ],
          FilledButton(
            onPressed:
                working || !session.initialized ? null : () => act(submit),
            child: Text(
              working
                  ? '请稍候…'
                  : mode == 'login'
                      ? '登录'
                      : mode == 'register'
                          ? '注册并登录'
                          : '重置密码',
            ),
          ),
          Wrap(
            spacing: 12,
            children: [
              for (final entry in {
                'login': '邮箱登录',
                'register': '注册账户',
                'reset': '忘记密码',
              }.entries)
                TextButton(
                  onPressed: working
                      ? null
                      : () => setState(() {
                            mode = entry.key;
                            password.clear();
                            code.clear();
                          }),
                  child: Text(entry.value),
                ),
            ],
          ),
          const Text('离线时仍可在连接与节点页面使用已保存的配置。'),
          OutlinedButton(
              onPressed: working
                  ? null
                  : () => act(() async {
                        await globalState.appController.restartCore();
                      }),
              child: const Text('诊断：重新初始化代理核心')),
        ],
      );
    }
    final traffic = session.overview?['traffic'] as Map<String, dynamic>?;
    final product = session.overview?['product'] as Map<String, dynamic>?;
    final used = traffic == null
        ? null
        : integer(traffic['uploadedBytes']) +
            integer(traffic['downloadedBytes']);
    final allowance =
        traffic == null ? null : integer(traffic['allowanceBytes']);
    final remaining =
        allowance == null ? null : (allowance - used!).clamp(0, allowance);
    return BusinessBody(
      children: [
        Text(
          session.email ?? '我的账户',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (session.notice != null) Text('${session.notice}。已保存的代理配置不会因此清空。'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(product?['name'] as String? ?? '套餐信息待刷新'),
                const SizedBox(height: 12),
                Text(
                  traffic == null
                      ? '流量信息待刷新'
                      : '已使用 ${bytesText(used!)} / ${bytesText(allowance!)}',
                ),
                if (remaining != null) Text('剩余 ${bytesText(remaining)}'),
                Text('到期时间：${session.overview?['expiresAt'] ?? '长期有效或待刷新'}'),
                Text(
                  '余额：${session.balanceMinor == null ? '待刷新' : money(session.balanceMinor!, session.currencySymbol)}',
                ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: working
                  ? null
                  : () => act(() async {
                        await ref.read(solutionSubscriptionProvider).refresh();
                        await session.refreshAccount();
                      }, success: '订阅已更新'),
              icon: const Icon(Icons.sync),
              label: const Text('刷新订阅'),
            ),
            OutlinedButton(
              onPressed: () =>
                  globalState.appController.toPage(PageLabel.proxies),
              child: const Text('选择节点'),
            ),
            OutlinedButton(
              onPressed: () =>
                  globalState.appController.toPage(PageLabel.dashboard),
              child: const Text('连接与网络状态'),
            ),
            TextButton(
              onPressed: working ? null : () => act(session.refreshAccount),
              child: const Text('刷新账户'),
            ),
          ],
        ),
        if (session.pendingMutations.isNotEmpty)
          const Text('有操作结果尚未确认，请先查看订单或工单，避免重复提交。'),
        ExpansionTile(
          title: const Text('公告'),
          children: [
            SizedBox(
              height: 260,
              child: RemotePanel(
                load: () => session.request('/api/v1/notices'),
                builder: (data, refresh) => ListView(
                  children: [
                    for (final item in objects(object(data)['items']))
                      ListTile(
                        title: Text(string(item['title'])),
                        onTap: () => uiAction(context, () async {
                          final notice = object(
                            await session.request(
                              '/api/v1/notices/${Uri.encodeComponent(string(item['id']))}',
                            ),
                          );
                          if (!context.mounted) return;
                          await showDialog<void>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: Text(string(notice['title'])),
                              content: SingleChildScrollView(
                                child: SelectableText(
                                  string(notice['content']),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          );
                        }),
                      ),
                    TextButton(onPressed: refresh, child: const Text('刷新公告')),
                  ],
                ),
              ),
            ),
          ],
        ),
        OutlinedButton(
          onPressed: working
              ? null
              : () => act(() async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('退出登录？'),
                        content: const Text('退出后需要重新登录以刷新账户和订阅。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('退出登录'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) await session.clear();
                  }),
          child: const Text('退出登录'),
        ),
      ],
    );
  }
}
