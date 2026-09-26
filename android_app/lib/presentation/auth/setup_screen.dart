import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import 'auth_controller.dart';
import 'widgets/hero_tv_banner.dart';

/// The first screen a signed-out user sees.
///
/// Layout follows the supplied reference: branding + settings gear, a hero
/// banner, a "Choose Xtreaming" pill, two side-by-side source cards, then a
/// full-width Xtream List card that leads into the real login form.
///
/// Playlist and Single Channel open the user-added sources
/// (`presentation/custom_sources/`), which are independent of the Xtream
/// session: they play through the same player but never touch the Xtream
/// catalogue or login.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  @override
  void initState() {
    super.initState();
    // So the Xtream card can say how many playlists are already saved.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider.notifier).loadSavedAccounts();
    });
  }

  Widget _header(TextTheme text) => Row(
        children: [
          Expanded(child: Text('MY IPTV', style: text.displaySmall)),
          IconButton(
            onPressed: () => context.push(Routes.settings),
            icon: const Icon(Icons.settings_rounded),
            color: AppColors.textPrimary,
            iconSize: 26,
            tooltip: 'Settings',
            // Visible when reached with the TV remote.
            focusColor: AppColors.accentSoft,
          ),
        ],
      );

  Widget _choose({bool autofocus = false}) => Center(
        child: _ChoosePill(
          label: 'Choose Xtreaming',
          autofocus: autofocus,
          onTap: () => context.push(Routes.xtreamLogin),
        ),
      );

  // IntrinsicHeight, not a bare `Row(crossAxisAlignment: stretch)`: inside a
  // ListView the Row gets unbounded height, and `stretch` alone then asks
  // for infinity — which crashed layout every frame and left the first-run
  // screen permanently black. IntrinsicHeight measures the two cards first
  // so both still end up the same height.
  Widget _sourceRow() => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _SourceCard(
                title: 'Playlist',
                description: 'Explore your all playlist channels',
                icon: Icons.subscriptions_rounded,
                enabled: true,
                onTap: () => context.push(Routes.customPlaylists),
              ),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: _SourceCard(
                title: 'Single Channel',
                description: 'Play channel with streaming link',
                icon: Icons.podcasts_rounded,
                enabled: true,
                onTap: () => context.push(Routes.customChannels),
              ),
            ),
          ],
        ),
      );

  Widget _xtreamCard(List<Object?> saved) => _SourceCard(
        title: 'Xtream List',
        description: saved.isEmpty
            ? 'Add your playlist (via XC API)'
            : '${saved.length} saved playlist'
                '${saved.length == 1 ? '' : 's'} · add another',
        icon: Icons.cast_connected_rounded,
        enabled: true,
        wide: true,
        onTap: () => context.push(
          // With something already saved, go straight to the account
          // switcher; otherwise to the form that creates the first one.
          saved.isEmpty ? Routes.xtreamLogin : Routes.accounts,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final saved = ref.watch(authControllerProvider).savedAccounts;
    final size = MediaQuery.sizeOf(context);

    // TV / landscape: everything on one screen, no scrolling — the banner
    // on the left, every option on the right, scaled down to fit whatever
    // the display is. (On a TV the stacked phone layout pushed the options
    // below the fold, and the remote could not scroll back up to Settings.)
    if (size.width > size.height && size.width >= 640) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                Insets.xl, Insets.md, Insets.xl, Insets.lg),
            child: Column(
              children: [
                _header(text),
                const SizedBox(height: Insets.md),
                Expanded(
                  child: Row(
                    children: [
                      const Expanded(
                        flex: 5,
                        child: Center(child: HeroTvBanner()),
                      ),
                      const SizedBox(width: Insets.xl),
                      Expanded(
                        flex: 6,
                        child: LayoutBuilder(
                          builder: (context, box) => Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: SizedBox(
                                width: box.maxWidth,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _choose(autofocus: true),
                                    const SizedBox(height: Insets.lg),
                                    _sourceRow(),
                                    const SizedBox(height: Insets.md),
                                    _xtreamCard(saved),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Insets.lg, Insets.md, Insets.lg, Insets.xxl),
          children: [
            _header(text),
            const SizedBox(height: Insets.md),
            const HeroTvBanner(),
            const SizedBox(height: Insets.lg),
            // Primary call to action. Goes to the same place as the Xtream
            // List card below, because that is the one real way in.
            _choose(),
            const SizedBox(height: Insets.xl),
            _sourceRow(),
            const SizedBox(height: Insets.md),
            _xtreamCard(saved),
          ],
        ),
      ),
    );
  }
}

class _ChoosePill extends StatelessWidget {
  const _ChoosePill({
    required this.label,
    required this.onTap,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(Radii.pill),
        focusColor: AppColors.accentSoft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              Insets.sm, Insets.sm, Insets.xl, Insets.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.podcasts_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: Insets.md),
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One source option. Title top, icon tile in the middle, description below —
/// the stacked arrangement from the reference.
class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.enabled,
    required this.onTap,
    this.wide = false,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final iconTile = Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: enabled ? AppColors.accent : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Icon(
        icon,
        color: enabled ? Colors.white : AppColors.textTertiary,
        size: 26,
      ),
    );

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.lg),
        focusColor: AppColors.accentSoft,
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: text.titleLarge?.copyWith(
                        color: enabled
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  if (!enabled) const _SoonBadge(),
                ],
              ),
              const SizedBox(height: Insets.md),
              if (wide)
                Row(
                  children: [
                    iconTile,
                    const Spacer(),
                    Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: const Icon(Icons.arrow_forward_rounded,
                          color: AppColors.textPrimary, size: 20),
                    ),
                  ],
                )
              else
                iconTile,
              const SizedBox(height: Insets.md),
              Text(
                description,
                style: text.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoonBadge extends StatelessWidget {
  const _SoonBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: const Text(
        'SOON',
        style: TextStyle(
          color: AppColors.textTertiary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
