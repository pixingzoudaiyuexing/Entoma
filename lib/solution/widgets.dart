import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'session.dart';

String money(int minor, String symbol) =>
    '$symbol${(minor / 100).toStringAsFixed(2)}';
String bytesText(int bytes) => bytes >= 1073741824
    ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MB';

Future<void> uiAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
    }
  } catch (error) {
    if (!context.mounted) return;
    final message = error is SolutionError
        ? error.toString()
        : const SolutionError('INVALID_RESPONSE').toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error is SolutionError && error.outcomeUnknown
              ? '$message。结果尚未确认，请先查看最新记录，勿重复提交。'
              : message,
        ),
      ),
    );
  }
}

class BusinessBody extends StatelessWidget {
  final List<Widget> children;
  const BusinessBody({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              for (final child in children)
                Padding(
                    padding: const EdgeInsets.only(bottom: 16), child: child),
            ],
          ),
        ),
      );
}

class AccountGate extends ConsumerWidget {
  final Widget child;
  const AccountGate({super.key, required this.child});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(solutionSessionProvider);
    if (!session.authenticated) {
      return BusinessBody(
        children: [
          const Text('登录后查看账户服务'),
          FilledButton(
            onPressed: () => globalState.appController.toPage(PageLabel.xboard),
            child: const Text('前往登录'),
          ),
        ],
      );
    }
    return KeyedSubtree(key: ValueKey(session.generation), child: child);
  }
}

class RemotePanel extends StatefulWidget {
  final Future<Object?> Function() load;
  final Widget Function(Object? value, VoidCallback refresh) builder;
  const RemotePanel({super.key, required this.load, required this.builder});
  @override
  State<RemotePanel> createState() => _RemotePanelState();
}

class _RemotePanelState extends State<RemotePanel> {
  late Future<Object?> future;
  @override
  void initState() {
    super.initState();
    future = widget.load();
  }

  void refresh() => setState(() {
        future = widget.load();
      });
  @override
  Widget build(BuildContext context) => FutureBuilder<Object?>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return BusinessBody(
              children: [
                Text(
                  snapshot.error is SolutionError
                      ? snapshot.error.toString()
                      : '暂时无法加载，请稍后重试',
                ),
                OutlinedButton(onPressed: refresh, child: const Text('重试')),
              ],
            );
          }
          try {
            return widget.builder(snapshot.data, refresh);
          } catch (_) {
            return const Center(child: Text('数据暂不可用，请刷新'));
          }
        },
      );
}

class PendingReviewButton extends ConsumerWidget {
  final String operationKey;
  final int generation;
  const PendingReviewButton({
    super.key,
    required this.operationKey,
    required this.generation,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
        onPressed: () => uiAction(context, () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('已核对最新记录？'),
              content: const Text(
                '结果未知不代表失败。请先核对订单、工单或邀请码，避免重复操作。确认后仅允许你主动发起新的操作，不会自动重试上次请求。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('继续核对'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('已核对，允许新操作'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            await ref
                .read(solutionSessionProvider)
                .acknowledgeNewIntent(operationKey, generation);
          }
        }),
        child: const Text('核对后开始新的操作'),
      );
}
