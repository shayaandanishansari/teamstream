import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../identity/identity.dart';
import '../identity/pick_name_screen.dart';
import '../models/member.dart';
import '../theme.dart';
import 'board/board_screen.dart';
import 'calendar/calendar_screen.dart';
import 'dashboard/dashboard_screen.dart';

/// Decides between "pick your name" and the app shell.
class RootGate extends ConsumerWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meId = ref.watch(identityProvider);
    if (meId == null) return const PickNameScreen();
    return const AppShell();
  }
}

class _NavDest {
  final IconData icon;
  final String label;
  const _NavDest(this.icon, this.label);
}

const _destinations = [
  _NavDest(Icons.grid_view_rounded, 'Board'),
  _NavDest(Icons.insights_rounded, 'Dashboard'),
  _NavDest(Icons.calendar_month_rounded, 'Calendar'),
];

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const _pages = [BoardScreen(), DashboardScreen(), CalendarScreen()];

  Member? _me(WidgetRef ref) {
    final meId = ref.watch(identityProvider);
    for (final m in (ref.watch(membersProvider).asData?.value ?? const <Member>[])) {
      if (m.id == meId) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(actorSyncProvider);
    final me = _me(ref);
    final wide = MediaQuery.of(context).size.width >= 720;

    final appBar = AppBar(
      backgroundColor: AppColors.bg,
      elevation: 0,
      titleSpacing: 20,
      title: Row(
        children: [
          Text('TeamStream', style: displayFont(size: 24, weight: FontWeight.w900)),
          const Spacer(),
          if (me != null)
            _MeChip(member: me, onTap: () => ref.read(identityProvider.notifier).logout()),
        ],
      ),
    );

    if (wide) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              backgroundColor: AppColors.card,
              indicatorColor: AppColors.tealSoft,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
              ],
            ),
            const VerticalDivider(width: 1, color: AppColors.line),
            Expanded(
              child: Scaffold(
                backgroundColor: AppColors.bg,
                appBar: appBar,
                body: IndexedStack(index: _index, children: _pages),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: appBar,
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: AppColors.card,
        indicatorColor: AppColors.tealSoft,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}

class _MeChip extends StatelessWidget {
  final Member member;
  final VoidCallback onTap;
  const _MeChip({required this.member, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.line, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: hexToColor(member.color), shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(member.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Icons.unfold_more_rounded, size: 15, color: AppColors.inkDim),
          ],
        ),
      ),
    );
  }
}
