import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../downloads/downloads_screen.dart';
import '../epg/epg_screen.dart';
import '../home/home_screen.dart';
import '../notifications/notification_onboarding.dart';
import '../profile/profile_screen.dart';
import '../../services/player/pip_service.dart';
import '../../services/player/player_controller.dart';
import '../providers.dart';

/// The four-tab shell from the design screenshots: Home / EPG / Downloads /
/// Profile, in a floating rounded bar over a true-black background.
///
/// Tabs are kept alive with an IndexedStack so switching back does not
/// re-run every fetch (spec §44) — but each tab builds lazily the first time
/// it is opened, so a cold start does not construct all four.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  late final List<bool> _visited = [true, false, false, false];

  @override
  void initState() {
    super.initState();
    // First open after bootstrap only (remembered in LocalStore): explain
    // notifications before the system is ever asked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        maybeShowNotificationOnboarding(context, ref.read(localStoreProvider)),
      );
    });
  }

  static const _tabs = <_TabSpec>[
    _TabSpec('Home', Icons.home_outlined, Icons.home_rounded),
    _TabSpec('EPG', Icons.grid_view_outlined, Icons.grid_view_rounded),
    _TabSpec('Downloads', Icons.download_outlined, Icons.download_rounded),
    _TabSpec('Profile', Icons.person_outline_rounded, Icons.person_rounded),
  ];

  void _select(int i) {
    if (_index == i) return;
    // Tabs stay alive in the IndexedStack, so an inline player (EPG) would
    // keep playing audio behind another tab. Leaving a tab stops it.
    unawaited(PlayerController.stopActive());
    setState(() {
      _index = i;
      _visited[i] = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(isTvProvider);

    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _index,
        children: [
          _lazy(0, const HomeScreen()),
          _lazy(1, const EpgScreen()),
          _lazy(2, const DownloadsScreen()),
          _lazy(3, const ProfileScreen()),
        ],
      ),
      // Hidden while a tab plays fullscreen in place, and inside a PiP
      // window (the window shows the whole activity, bar included).
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: PipService.inPip,
        builder: (context, pip, _) => pip || ref.watch(shellNavHiddenProvider)
            ? const SizedBox.shrink()
            : _FloatingNavBar(
                index: _index,
                tabs: _tabs,
                onSelect: _select,
                tv: isTv,
              ),
      ),
    );
  }

  Widget _lazy(int i, Widget child) =>
      _visited[i] ? child : const SizedBox.shrink();
}

class _TabSpec {
  const _TabSpec(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.index,
    required this.tabs,
    required this.onSelect,
    required this.tv,
  });

  final int index;
  final List<_TabSpec> tabs;
  final ValueChanged<int> onSelect;
  final bool tv;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Radii.pill);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.md),
        // Deliberately not a BackdropFilter: Home scrolls under the bar
        // (extendBody), and a live blur there was re-run every scroll frame,
        // which made scrolling stutter. A dense translucent fill reads as
        // glass without the per-frame cost.
        // On a TV/landscape screen a full-width bar covered a whole row of
        // content; keep it a compact centred pill there.
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width >= 900
                  ? 560
                  : double.infinity,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Container(
                // 66 was 5px too short for a selected phone tab: icon (22) + its
                // selected-state padding (8+8) + the label gap (2) + the label
                // text overflowed the Column's available height by exactly
                // 5.0px (confirmed via a real-device layout exception), which
                // painted a yellow/black overflow banner over the nav bar.
                height: tv ? 76 : 72,
                decoration: BoxDecoration(
                  color: const Color(0xF21B1B1D),
                  borderRadius: radius,
                  border: Border.all(color: const Color(0x1FFFFFFF)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      _NavItem(
                        spec: tabs[i],
                        selected: i == index,
                        onTap: () => onSelect(i),
                        tv: tv,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.spec,
    required this.selected,
    required this.onTap,
    required this.tv,
  });

  final _TabSpec spec;
  final bool selected;
  final VoidCallback onTap;
  final bool tv;

  /// Darker than the glass around it, so the selected tab reads as a
  /// recessed capsule rather than a coloured blob.
  static const _capsule = Color(0xE60A0A0B);

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textPrimary;
    final iconSize = tv ? 26.0 : 22.0;
    final radius = BorderRadius.circular(Radii.pill);
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: spec.label,
        // The whole cell is the target, padding included. The padding
        // around the capsule used to swallow taps, so a tap near an edge
        // "did nothing" and people had to press 2-3 times.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: Insets.xs + 2,
              horizontal: 2,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                // TV needs a visible focus ring on every interactive item (§36).
                focusColor: AppColors.accentSoft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    color: selected ? _capsule : Colors.transparent,
                    borderRadius: radius,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        selected ? spec.activeIcon : spec.icon,
                        color: color,
                        size: iconSize,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        spec.label,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          color: color,
                          fontSize: tv ? 13 : 11,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
