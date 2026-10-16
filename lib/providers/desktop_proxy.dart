import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/common/desktop_proxy.dart';
import 'package:fl_clash/state.dart';

final desktopProxyCoordinatorProvider =
    ChangeNotifierProvider<DesktopProxyCoordinator>(
        (ref) => globalState.appController.desktopProxy);
