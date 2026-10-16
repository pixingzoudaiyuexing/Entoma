import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:fl_clash/providers/desktop_proxy.dart';
import 'package:fl_clash/widgets/desktop_proxy_status.dart';
import 'package:fl_clash/common/desktop_proxy.dart';

class ProxyHelperItem extends StatefulWidget {
  const ProxyHelperItem({super.key});
  @override
  State<ProxyHelperItem> createState() => _ProxyHelperItemState();
}

class _ProxyHelperItemState extends State<ProxyHelperItem> {
  bool pending = false;
  String? message;
  Future<void> action(Future<Map<String, dynamic>> Function() operation) async {
    if (pending) return;
    setState(() => pending = true);
    try {
      final status = await operation();
      if (mounted)
        setState(() => message = switch (status['registration']) {
              'enabled' => '系统代理服务已启用',
              'requiresApproval' => '请在系统设置中允许 Entoma 后重试',
              'notRegistered' => '系统代理服务尚未启用',
              _ => '请检查系统代理服务状态',
            });
    } catch (error) {
      if (mounted) setState(() => message = desktopProxyFailure(error));
    } finally {
      if (mounted) setState(() => pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListItem(
      title: const Text('系统代理服务'),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(message ?? '首次启用需要系统确认；之后通过受限服务管理系统代理。'),
        Wrap(children: [
          TextButton(
              onPressed: pending ? null : () => action(proxy!.registerHelper),
              child: const Text('启用')),
          TextButton(
              onPressed: pending ? null : () => action(proxy!.helperStatus),
              child: const Text('检查状态')),
          TextButton(
              onPressed: pending ? null : () => action(proxy!.unregisterHelper),
              child: const Text('停用')),
        ]),
      ]));
}

class VPNItem extends ConsumerWidget {
  const VPNItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final enable =
        ref.watch(vpnSettingProvider.select((state) => state.enable));
    return ListItem.switchItem(
      title: const Text("VPN"),
      subtitle: Text(appLocalizations.vpnEnableDesc),
      delegate: SwitchDelegate(
        value: enable,
        onChanged: (value) async {
          ref.read(vpnSettingProvider.notifier).updateState(
                (state) => state.copyWith(
                  enable: value,
                ),
              );
        },
      ),
    );
  }
}

class TUNItem extends ConsumerWidget {
  const TUNItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final enable =
        ref.watch(patchClashConfigProvider.select((state) => state.tun.enable));

    return ListItem.switchItem(
      title: Text(appLocalizations.tun),
      subtitle: Text(appLocalizations.tunDesc),
      delegate: SwitchDelegate(
        value: enable,
        onChanged: (value) async {
          ref.read(patchClashConfigProvider.notifier).updateState(
                (state) => state.copyWith.tun(
                  enable: value,
                ),
              );
        },
      ),
    );
  }
}

class AllowBypassItem extends ConsumerWidget {
  const AllowBypassItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final allowBypass =
        ref.watch(vpnSettingProvider.select((state) => state.allowBypass));
    return ListItem.switchItem(
      title: Text(appLocalizations.allowBypass),
      subtitle: Text(appLocalizations.allowBypassDesc),
      delegate: SwitchDelegate(
        value: allowBypass,
        onChanged: (bool value) async {
          ref.read(vpnSettingProvider.notifier).updateState(
                (state) => state.copyWith(
                  allowBypass: value,
                ),
              );
        },
      ),
    );
  }
}

class VpnSystemProxyItem extends ConsumerWidget {
  const VpnSystemProxyItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final systemProxy =
        ref.watch(vpnSettingProvider.select((state) => state.systemProxy));
    return ListItem.switchItem(
      title: Text(appLocalizations.systemProxy),
      subtitle: Text(appLocalizations.systemProxyDesc),
      delegate: SwitchDelegate(
        value: systemProxy,
        onChanged: (bool value) async {
          ref.read(vpnSettingProvider.notifier).updateState(
                (state) => state.copyWith(
                  systemProxy: value,
                ),
              );
        },
      ),
    );
  }
}

class SystemProxyItem extends ConsumerWidget {
  const SystemProxyItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final systemProxy =
        ref.watch(networkSettingProvider.select((state) => state.systemProxy));
    final desktop = Platform.isMacOS || Platform.isWindows;
    final coordinator =
        desktop ? ref.watch(desktopProxyCoordinatorProvider) : null;

    return ListItem.switchItem(
      title: Text(appLocalizations.systemProxy),
      subtitle: coordinator == null
          ? Text(appLocalizations.systemProxyDesc)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DesktopProxyStatusText(coordinator: coordinator),
              if (coordinator.phase == DesktopProxyPhase.failed)
                TextButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                    onPressed: () =>
                        globalState.appController.retrySystemProxy()),
            ]),
      delegate: SwitchDelegate(
        value: coordinator?.desired ?? systemProxy,
        onChanged: (bool value) async {
          if (desktop) {
            await globalState.appController.setSystemProxyEnabled(value);
          } else {
            ref.read(networkSettingProvider.notifier).updateState(
                  (state) => state.copyWith(
                    systemProxy: value,
                  ),
                );
          }
        },
      ),
    );
  }
}

class Ipv6Item extends ConsumerWidget {
  const Ipv6Item({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final ipv6 = ref.watch(vpnSettingProvider.select((state) => state.ipv6));
    return ListItem.switchItem(
      title: const Text("IPv6"),
      subtitle: Text(appLocalizations.ipv6InboundDesc),
      delegate: SwitchDelegate(
        value: ipv6,
        onChanged: (bool value) async {
          ref.read(vpnSettingProvider.notifier).updateState(
                (state) => state.copyWith(
                  ipv6: value,
                ),
              );
        },
      ),
    );
  }
}

class AutoSetSystemDnsItem extends ConsumerWidget {
  const AutoSetSystemDnsItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final autoSetSystemDns = ref.watch(
        networkSettingProvider.select((state) => state.autoSetSystemDns));
    return ListItem.switchItem(
      title: Text(appLocalizations.autoSetSystemDns),
      delegate: SwitchDelegate(
        value: autoSetSystemDns,
        onChanged: (bool value) async {
          ref.read(networkSettingProvider.notifier).updateState(
                (state) => state.copyWith(
                  autoSetSystemDns: value,
                ),
              );
        },
      ),
    );
  }
}

class TunStackItem extends ConsumerWidget {
  const TunStackItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final stack =
        ref.watch(patchClashConfigProvider.select((state) => state.tun.stack));

    return ListItem.options(
      title: Text(appLocalizations.stackMode),
      subtitle: Text(stack.name),
      delegate: OptionsDelegate<TunStack>(
        value: stack,
        options: TunStack.values,
        textBuilder: (value) => value.name,
        onChanged: (value) {
          if (value == null) {
            return;
          }
          ref.read(patchClashConfigProvider.notifier).updateState(
                (state) => state.copyWith.tun(
                  stack: value,
                ),
              );
        },
        title: appLocalizations.stackMode,
      ),
    );
  }
}

class BypassDomainItem extends StatelessWidget {
  const BypassDomainItem({super.key});

  _initActions(BuildContext context, WidgetRef ref) {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      context.commonScaffoldState?.actions = [
        IconButton(
          onPressed: () async {
            final res = await globalState.showMessage(
              title: appLocalizations.reset,
              message: TextSpan(
                text: appLocalizations.resetTip,
              ),
            );
            if (res != true) {
              return;
            }
            ref.read(networkSettingProvider.notifier).updateState(
                  (state) => state.copyWith(
                    bypassDomain: defaultBypassDomain,
                  ),
                );
          },
          tooltip: appLocalizations.reset,
          icon: const Icon(
            Icons.replay,
          ),
        )
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      title: Text(appLocalizations.bypassDomain),
      subtitle: Text(appLocalizations.bypassDomainDesc),
      delegate: OpenDelegate(
        blur: false,
        title: appLocalizations.bypassDomain,
        widget: Consumer(
          builder: (_, ref, __) {
            _initActions(context, ref);
            final bypassDomain = ref.watch(
                networkSettingProvider.select((state) => state.bypassDomain));
            return ListInputPage(
              title: appLocalizations.bypassDomain,
              items: bypassDomain,
              titleBuilder: (item) => Text(item),
              onChange: (items) {
                ref.read(networkSettingProvider.notifier).updateState(
                      (state) => state.copyWith(
                        bypassDomain: List.from(items),
                      ),
                    );
              },
            );
          },
        ),
      ),
    );
  }
}

class RouteModeItem extends ConsumerWidget {
  const RouteModeItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final routeMode =
        ref.watch(networkSettingProvider.select((state) => state.routeMode));
    return ListItem<RouteMode>.options(
      title: Text(appLocalizations.routeMode),
      subtitle: Text(Intl.message("routeMode_${routeMode.name}")),
      delegate: OptionsDelegate<RouteMode>(
        title: appLocalizations.routeMode,
        options: RouteMode.values,
        onChanged: (RouteMode? value) {
          if (value == null) {
            return;
          }
          ref.read(networkSettingProvider.notifier).updateState(
                (state) => state.copyWith(
                  routeMode: value,
                ),
              );
        },
        textBuilder: (routeMode) => Intl.message(
          "routeMode_${routeMode.name}",
        ),
        value: routeMode,
      ),
    );
  }
}

class RouteAddressItem extends ConsumerWidget {
  const RouteAddressItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final bypassPrivate = ref.watch(networkSettingProvider
        .select((state) => state.routeMode == RouteMode.bypassPrivate));
    if (bypassPrivate) {
      return Container();
    }
    return ListItem.open(
      title: Text(appLocalizations.routeAddress),
      subtitle: Text(appLocalizations.routeAddressDesc),
      delegate: OpenDelegate(
        blur: false,
        maxWidth: 360,
        title: appLocalizations.routeAddress,
        widget: Consumer(
          builder: (_, ref, __) {
            final routeAddress = ref.watch(
              patchClashConfigProvider.select(
                (state) => state.tun.routeAddress,
              ),
            );
            return ListInputPage(
              title: appLocalizations.routeAddress,
              items: routeAddress,
              titleBuilder: (item) => Text(item),
              onChange: (items) {
                ref.read(patchClashConfigProvider.notifier).updateState(
                      (state) => state.copyWith.tun(
                        routeAddress: List.from(items),
                      ),
                    );
              },
            );
          },
        ),
      ),
    );
  }
}

final networkItems = [
  if (Platform.isAndroid) const VPNItem(),
  if (Platform.isAndroid)
    ...generateSection(
      title: "VPN",
      items: [
        const VpnSystemProxyItem(),
        const BypassDomainItem(),
        const AllowBypassItem(),
        const Ipv6Item(),
      ],
    ),
  if (system.isDesktop)
    ...generateSection(
      title: appLocalizations.system,
      items: [
        SystemProxyItem(),
        if (Platform.isMacOS) const ProxyHelperItem(),
        BypassDomainItem(),
      ],
    ),
  ...generateSection(
    title: appLocalizations.options,
    items: [
      if (system.isDesktop) const TUNItem(),
      if (Platform.isMacOS) const AutoSetSystemDnsItem(),
      const TunStackItem(),
      if (!system.isDesktop) ...[
        const RouteModeItem(),
        const RouteAddressItem(),
      ]
    ],
  ),
];

class NetworkListView extends ConsumerWidget {
  const NetworkListView({super.key});

  _initActions(BuildContext context, WidgetRef ref) {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      context.commonScaffoldState?.actions = [
        IconButton(
          onPressed: () async {
            final res = await globalState.showMessage(
              title: appLocalizations.reset,
              message: TextSpan(
                text: appLocalizations.resetTip,
              ),
            );
            if (res != true) {
              return;
            }
            ref.read(vpnSettingProvider.notifier).updateState(
                  (state) => defaultVpnProps.copyWith(
                    accessControl: state.accessControl,
                  ),
                );
            ref.read(patchClashConfigProvider.notifier).updateState(
                  (state) => state.copyWith(
                    tun: defaultTun,
                  ),
                );
          },
          tooltip: appLocalizations.reset,
          icon: const Icon(
            Icons.replay,
          ),
        )
      ];
    });
  }

  @override
  Widget build(BuildContext context, ref) {
    _initActions(context, ref);
    return generateListView(
      networkItems,
    );
  }
}
