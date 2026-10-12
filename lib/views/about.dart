import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Use the same Entoma release source as automatic update checks.
final releaseUpdateCheckProvider =
    Provider<Future<Map<String, dynamic>?> Function()>(
  (_) => request.checkForUpdate,
);

@immutable
class Contributor {
  final String avatar;
  final String name;
  final String link;

  const Contributor({
    required this.avatar,
    required this.name,
    required this.link,
  });
}

class AboutView extends ConsumerWidget {
  const AboutView({super.key});

  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    if (!context.mounted) return;
    final scaffold = context.commonScaffoldState;
    if (scaffold?.mounted != true) return;
    // Capture the loader before waiting; the page/ref may be disposed later.
    final load = ref.read(releaseUpdateCheckProvider);
    try {
      Map<String, dynamic>? result;
      bool failed = false;
      await scaffold!.loadingRun<void>(() async {
        try {
          result = await load().timeout(const Duration(seconds: 25));
        } catch (_) {
          failed = true;
        }
      }, title: appLocalizations.checkUpdate);
      if (!context.mounted) return;
      if (failed) throw StateError('Release lookup failed');
      if (result != null) {
        await globalState.appController.checkUpdateResultHandle(
          data: result,
          manual: true,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已是最新版本')),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('检查更新失败，请检查网络后重试'),
        action: SnackBarAction(
            label: '重试', onPressed: () => _checkUpdate(context, ref)),
      ));
    }
  }

  List<Widget> _buildMoreSection(BuildContext context, WidgetRef ref) {
    return generateSection(
      separated: false,
      title: appLocalizations.more,
      items: [
        ListItem(
          title: Text(appLocalizations.checkUpdate),
          onTap: () {
            _checkUpdate(context, ref);
          },
        ),
        ListItem(
          title: const Text("Telegram"),
          onTap: () {
            globalState.openUrl(
              "https://t.me/FlClash",
            );
          },
          trailing: const Icon(Icons.launch),
        ),
        ListItem(
          title: Text(appLocalizations.project),
          onTap: () {
            globalState.openUrl(
              "https://github.com/$repository",
            );
          },
          trailing: const Icon(Icons.launch),
        ),
        ListItem(
          title: Text(appLocalizations.core),
          onTap: () {
            globalState.openUrl(
              "https://github.com/chen08209/Clash.Meta/tree/FlClash",
            );
          },
          trailing: const Icon(Icons.launch),
        ),
      ],
    );
  }

  List<Widget> _buildContributorsSection() {
    const contributors = [
      Contributor(
        avatar: "assets/images/avatars/june2.jpg",
        name: "June2",
        link: "https://t.me/Jibadong",
      ),
      Contributor(
        avatar: "assets/images/avatars/arue.jpg",
        name: "Arue",
        link: "https://t.me/xrcm6868",
      ),
    ];
    return generateSection(
      separated: false,
      title: appLocalizations.otherContributors,
      items: [
        ListItem(
          title: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Wrap(
              spacing: 24,
              children: [
                for (final contributor in contributors)
                  Avatar(
                    contributor: contributor,
                  ),
              ],
            ),
          ),
        )
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = [
      ListTile(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Consumer(builder: (_, ref, ___) {
              return _DeveloperModeDetector(
                child: Wrap(
                  spacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Image.asset(
                        'assets/images/icon.png',
                        width: 64,
                        height: 64,
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          appName,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          globalState.packageInfo.version,
                          style: Theme.of(context).textTheme.labelLarge,
                        )
                      ],
                    )
                  ],
                ),
                onEnterDeveloperMode: () {
                  ref.read(appSettingProvider.notifier).updateState(
                        (state) => state.copyWith(developerMode: true),
                      );
                  context.showNotifier(appLocalizations.developerModeEnableTip);
                },
              );
            }),
            const SizedBox(
              height: 24,
            ),
            Text(
              appLocalizations.desc,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      const SizedBox(
        height: 12,
      ),
      ..._buildContributorsSection(),
      ..._buildMoreSection(context, ref),
    ];
    return Padding(
      padding: kMaterialListPadding.copyWith(
        top: 16,
        bottom: 16,
      ),
      child: generateListView(items),
    );
  }
}

class Avatar extends StatelessWidget {
  final Contributor contributor;

  const Avatar({
    super.key,
    required this.contributor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      child: Column(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircleAvatar(
              foregroundImage: AssetImage(
                contributor.avatar,
              ),
            ),
          ),
          const SizedBox(
            height: 4,
          ),
          Text(
            contributor.name,
            style: context.textTheme.bodySmall,
          )
        ],
      ),
      onTap: () {
        globalState.openUrl(contributor.link);
      },
    );
  }
}

class _DeveloperModeDetector extends StatefulWidget {
  final Widget child;
  final VoidCallback onEnterDeveloperMode;

  const _DeveloperModeDetector({
    required this.child,
    required this.onEnterDeveloperMode,
  });

  @override
  State<_DeveloperModeDetector> createState() => _DeveloperModeDetectorState();
}

class _DeveloperModeDetectorState extends State<_DeveloperModeDetector> {
  int _counter = 0;
  Timer? _timer;

  void _handleTap() {
    _counter++;
    if (_counter >= 5) {
      widget.onEnterDeveloperMode();
      _resetCounter();
    } else {
      _timer?.cancel();
      _timer = Timer(Duration(seconds: 1), _resetCounter);
    }
  }

  void _resetCounter() {
    _counter = 0;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: widget.child,
    );
  }
}
