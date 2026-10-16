import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/common/desktop_proxy.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/controller.dart';

final _desktopControllerProvider = Provider<AppController>((ref) {
  // Application replaces the initial controller with a navigator-bound one
  // after the first frame. UI must observe the new connection owner as well.
  void changed() => ref.invalidateSelf();
  globalState.appControllerChanges.addListener(changed);
  ref.onDispose(() => globalState.appControllerChanges.removeListener(changed));
  return globalState.appController;
});

final desktopProxyCoordinatorProvider =
    ChangeNotifierProvider<DesktopProxyCoordinator>((ref) => ref.watch(
        _desktopControllerProvider
            .select((controller) => controller.desktopProxy)));
