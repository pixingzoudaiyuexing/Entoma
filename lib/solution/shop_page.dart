import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'community_pages.dart';
import 'session.dart';
import 'widgets.dart';

class SolutionShopPage extends ConsumerWidget {
  const SolutionShopPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => AccountGate(
        child: RemotePanel(
          load: () =>
              ref.read(solutionSessionProvider).request('/api/v1/products'),
          builder: (data, refresh) {
            final products = objects(object(data)['products']);
            final session = ref.read(solutionSessionProvider);
            return BusinessBody(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '套餐与订单',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: refresh,
                      tooltip: '刷新套餐',
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(
                        appBar: _OrdersAppBar(),
                        body: OrdersPage(),
                      ),
                    ),
                  ),
                  child: const Text('查看订单与支付结果'),
                ),
                if (products.isEmpty) const Text('暂无可购买套餐，请稍后刷新。'),
                for (final product in products)
                  Card(
                    child: ListTile(
                      title: Text(string(product['name'])),
                      subtitle: Text('流量 ${product['dataAllowanceGb']} GB'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: product['available'] != true
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ProductPage(
                                    productId: string(product['id']),
                                    generation: session.generation,
                                  ),
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

class _OrdersAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _OrdersAppBar();
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => AppBar(title: const Text('我的订单'));
}

class ProductPage extends ConsumerStatefulWidget {
  final String productId;
  final int generation;
  const ProductPage({
    super.key,
    required this.productId,
    required this.generation,
  });
  @override
  ConsumerState<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends ConsumerState<ProductPage> {
  final coupon = TextEditingController();
  String? period;
  bool busy = false;
  @override
  void dispose() {
    coupon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(solutionSessionProvider);
    if (session.generation != widget.generation) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('账户已切换，请返回套餐列表。')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('套餐详情')),
      body: RemotePanel(
        load: () => session.request(
          '/api/v1/products/${Uri.encodeComponent(widget.productId)}',
        ),
        builder: (data, refresh) {
          final product = object(object(data)['product']);
          final prices = objects(product['prices']);
          return BusinessBody(
            children: [
              Text(
                string(product['name']),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text('流量 ${product['dataAllowanceGb']} GB'),
              if (product['speedLimitMbps'] != null)
                Text('速率上限 ${product['speedLimitMbps']} Mbps'),
              const Text('选择购买周期。续费资格、优惠及最终应付金额由服务端确认。'),
              for (final price in prices)
                RadioListTile<String>(
                  value: string(price['billingPeriod']),
                  groupValue: period,
                  title: Text(_periodText(string(price['billingPeriod']))),
                  subtitle: Text(
                    money(
                      integer(price['amountMinor']),
                      session.currencySymbol,
                    ),
                  ),
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                            period = value;
                          }),
                ),
              TextField(
                controller: coupon,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: '优惠码（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              FilledButton(
                onPressed: busy ||
                        period == null ||
                        session.pendingMutations.contains('order:create')
                    ? null
                    : () async {
                        setState(() {
                          busy = true;
                        });
                        await uiAction(context, () async {
                          if (session.generation != widget.generation) {
                            throw const SolutionError('STALE_SESSION');
                          }
                          final id = await session.mutate('order:create', (
                            mutation,
                          ) async {
                            final result = object(
                              await mutation.request(
                                '/api/v1/orders',
                                method: 'POST',
                                body: {
                                  'productId': widget.productId,
                                  'billingPeriod': period,
                                  if (coupon.text.trim().isNotEmpty)
                                    'promotionCode': coupon.text.trim(),
                                },
                              ),
                            );
                            return string(result['id']);
                          });
                          if (!context.mounted ||
                              session.generation != widget.generation) {
                            return;
                          }
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => OrderPage(
                                id: id,
                                generation: widget.generation,
                              ),
                            ),
                          );
                        });
                        if (mounted) {
                          setState(() {
                            busy = false;
                          });
                        }
                      },
                child: Text(busy ? '正在创建订单…' : '创建订单并查看应付金额'),
              ),
              if (session.pendingMutations.contains('order:create'))
                const Text('上次下单结果未知。请返回“我的订单”核对；客户端不会自动再次下单。'),
            ],
          );
        },
      ),
    );
  }
}

String _periodText(String value) =>
    const {
      'month': '月付',
      'quarter': '季付',
      'halfYear': '半年付',
      'year': '年付',
      'twoYears': '两年付',
      'threeYears': '三年付',
      'oneTime': '一次性',
    }[value] ??
    value;

class OrdersPage extends ConsumerWidget {
  const OrdersPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => AccountGate(
        child: RemotePanel(
          load: () =>
              ref.read(solutionSessionProvider).request('/api/v1/orders'),
          builder: (data, refresh) {
            final session = ref.read(solutionSessionProvider);
            final orders = objects(data).map(SolutionOrder.new).toList();
            return BusinessBody(
              children: [
                OutlinedButton.icon(
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新订单'),
                ),
                if (session.pendingMutations.contains('order:create'))
                  const Text('上次下单结果尚未确认，请核对以下记录。未确认前不会重复提交。'),
                if (session.pendingMutations.contains('order:create'))
                  PendingReviewButton(
                    operationKey: 'order:create',
                    generation: session.generation,
                  ),
                if (orders.isEmpty) const Text('暂无订单'),
                for (final order in orders)
                  ListTile(
                    title: Text(
                      '${money(order.amountMinor, session.currencySymbol)} · ${order.statusText}',
                    ),
                    subtitle: Text(order.createdAt.toLocal().toString()),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => OrderPage(
                            id: order.id, generation: session.generation),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
}

class OrderPage extends ConsumerStatefulWidget {
  final String id;
  final int generation;
  const OrderPage({super.key, required this.id, required this.generation});
  @override
  ConsumerState<OrderPage> createState() => _OrderPageState();
}

class _OrderPageState extends ConsumerState<OrderPage> {
  SolutionOrder? order;
  CheckoutAction? action;
  String? error;
  bool busy = false;
  Timer? timer;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (loading || !mounted) return;
    final session = ref.read(solutionSessionProvider);
    if (session.generation != widget.generation) {
      timer?.cancel();
      return;
    }
    loading = true;
    try {
      final value = await session.readOrder(widget.id, widget.generation);
      if (!mounted || session.generation != widget.generation) return;
      setState(() {
        order = value;
        error = null;
      });
      if (value.terminal) {
        timer?.cancel();
        unawaited(session.refreshAccount());
      }
    } catch (failure) {
      if (mounted && session.generation == widget.generation) {
        setState(() {
          error =
              failure is SolutionError ? failure.toString() : '暂时无法读取订单，请重试';
        });
      }
    } finally {
      loading = false;
    }
  }

  Future<void> checkout() async {
    final session = ref.read(solutionSessionProvider);
    final methods = objects(await session.request('/api/v1/billing/methods'));
    if (!mounted || session.generation != widget.generation) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('选择支付方式'),
        children: [
          for (final method in methods)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, string(method['id'])),
              child: Text(
                '${string(method['name'])} · 手续费 ${object(method['fee'])['percent']}% + '
                '${money(integer(object(method['fee'])['fixedMinor']), session.currencySymbol)}',
              ),
            ),
          if (methods.isEmpty)
            const Padding(padding: EdgeInsets.all(20), child: Text('暂无可用支付方式')),
        ],
      ),
    );
    if (chosen == null || !mounted || session.generation != widget.generation)
      return;
    final result = await session.mutate(
      'checkout:${widget.id}',
      (mutation) async => CheckoutAction(
        object(
          await mutation.request(
            '/api/v1/orders/${Uri.encodeComponent(widget.id)}/checkout',
            method: 'POST',
            body: {'paymentMethodId': chosen},
          ),
        ),
      ),
    );
    if (!mounted || session.generation != widget.generation) return;
    setState(() {
      action = result;
    });
    // Every action, including finished, still requires authoritative order reads.
    await refresh();
    if (!mounted || session.generation != widget.generation) return;
    timer?.cancel();
    if (order?.terminal == true) return;
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
    if (result.type == 'redirect') {
      await launchUrl(
        Uri.parse(result.payload!),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(solutionSessionProvider);
    if (session.generation != widget.generation) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('账户已切换，请返回订单列表。')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('订单与付款')),
      body: BusinessBody(
        children: [
          if (order == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (order != null) ...[
            Text(
              order!.statusText,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              '应付 ${money(order!.amountMinor, session.currencySymbol)}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text('以服务端订单状态为准，支付页面关闭不代表付款成功。'),
          ],
          if (error != null) Text(error!),
          if (action?.type == 'qrcode' && order?.terminal != true) ...[
            const Text('请使用对应支付应用扫码，支付后等待订单确认。'),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: action!.payload!, size: 240),
              ),
            ),
          ],
          if (action?.type == 'finished' && order?.terminal != true)
            const Text('支付请求已处理，正在等待服务端确认。'),
          if (action?.type == 'redirect' && order?.terminal != true)
            OutlinedButton(
              onPressed: () => uiAction(context, () async {
                await launchUrl(
                  Uri.parse(action!.payload!),
                  mode: LaunchMode.externalApplication,
                );
              }),
              child: const Text('重新打开支付页面'),
            ),
          OutlinedButton(onPressed: refresh, child: const Text('刷新支付结果')),
          if (order?.status == OrderStatus.pending) ...[
            FilledButton(
              onPressed: busy ||
                      action != null ||
                      session.orderOperationPending(widget.id)
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                      });
                      await uiAction(context, checkout);
                      if (mounted) {
                        setState(() {
                          busy = false;
                        });
                      }
                    },
              child: const Text('选择方式并付款'),
            ),
            TextButton(
              onPressed: busy || session.orderOperationPending(widget.id)
                  ? null
                  : () => uiAction(context, () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('取消此订单？'),
                            content: const Text('如果已付款，请先刷新支付结果。'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('返回'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('确认取消'),
                              ),
                            ],
                          ),
                        );
                        if (yes == true &&
                            mounted &&
                            session.generation == widget.generation) {
                          await session.mutate(
                            'cancel:${widget.id}',
                            (mutation) => mutation.request(
                              '/api/v1/orders/${Uri.encodeComponent(widget.id)}/cancel',
                              method: 'POST',
                              successField: 'cancelled',
                            ),
                          );
                          await refresh();
                        }
                      }),
              child: const Text('取消订单'),
            ),
          ],
          if (session.orderOperationPending(widget.id)) ...[
            const Text('上次付款或取消的结果尚未确认。待支付状态不能排除已有支付会话；请刷新订单，并核对支付应用的交易记录。'),
            const Text(
                '当前服务无法核验未完成的支付会话，客户端暂时保留操作保护。若状态持续未确认，请联系客服核查；不会自动再次付款或取消。'),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const SolutionSupportPage(),
              )),
              child: const Text('联系客服核查订单'),
            ),
          ],
        ],
      ),
    );
  }
}
