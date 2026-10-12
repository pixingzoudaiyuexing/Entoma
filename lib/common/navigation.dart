import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/solution/account_page.dart';
import 'package:fl_clash/solution/shop_page.dart';
import 'package:fl_clash/solution/community_pages.dart';
import 'package:fl_clash/views/views.dart';
import 'package:flutter/material.dart';

class Navigation {
  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) => [
    const NavigationItem(
      icon: Icon(Icons.account_circle_outlined),
      label: PageLabel.xboard,
      view: SolutionAccountPage(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
    ),
    const NavigationItem(
      icon: Icon(Icons.space_dashboard_outlined),
      label: PageLabel.dashboard,
      view: DashboardView(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
    ),
    const NavigationItem(
      icon: Icon(Icons.dns_outlined),
      label: PageLabel.proxies,
      view: ProxiesView(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
    ),
    const NavigationItem(
      icon: Icon(Icons.shopping_bag_outlined),
      label: PageLabel.plans,
      view: SolutionShopPage(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.more],
    ),
    const NavigationItem(
      icon: Icon(Icons.support_agent),
      label: PageLabel.onlineSupport,
      view: SolutionSupportPage(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.more],
    ),
    const NavigationItem(
      icon: Icon(Icons.people_outline),
      label: PageLabel.invite,
      view: SolutionReferralsPage(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.more],
    ),
    const NavigationItem(
      icon: Icon(Icons.article_outlined),
      label: PageLabel.profiles,
      view: ProfilesView(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.more],
    ),
    const NavigationItem(
      icon: Icon(Icons.settings_outlined),
      label: PageLabel.tools,
      view: ToolsView(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
    ),
    const NavigationItem(
      icon: Icon(Icons.receipt_long_outlined),
      label: PageLabel.logs,
      view: LogsView(),
      modes: [NavigationItemMode.desktop, NavigationItemMode.more],
    ),
  ];
}

final navigation = Navigation();
