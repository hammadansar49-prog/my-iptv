import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/account.dart';
import '../providers.dart';
import '../widgets/error_banner.dart';
import 'auth_controller.dart';

/// Saved Xtream accounts, and the switcher between them.
///
/// Multiple accounts were already supported by the storage layer
/// (`SecureStore` keeps a list plus an `activeAccountId`), so this screen is
/// the UI over what the auth repository could already do — no storage
/// migration was needed.
///
/// The M3u Playlist and Single Channel tabs exist because the reference
/// layout was requested, but they are visibly disabled: Xtream Codes is the
/// only authentication this backend has (AUDIT.md §2).
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  String? _busyAccountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider.notifier).loadSavedAccounts();
    });
  }

  Future<void> _use(Account account) async {
    final auth = ref.read(authControllerProvider.notifier);

    // Already the live session: no need to spend a provider connection
    // re-authenticating, just go through.
    if (ref.read(authControllerProvider).isSignedIn &&
        ref.read(authControllerProvider).account?.id == account.id) {
      context.go(Routes.home);
      return;
    }

    setState(() => _busyAccountId = account.id);
    final ok = await auth.signInWith(account);
    if (!mounted) return;
    setState(() => _busyAccountId = null);

    if (ok) {
      context.go(Routes.home);
    } else {
      final error = ref.read(authControllerProvider).error;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(error?.message ?? 'Could not connect to that account.'),
        ));
    }
  }

  Future<void> _remove(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text('Remove account?'),
        content: Text(
          '"${account.name}" will be removed from this device. '
          'Downloads already on the device are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      ref.read(accountSummaryStoreProvider).remove(account.id);
      await ref.read(authControllerProvider.notifier).removeAccount(account.id);
    }
  }

  void _notSupported(String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('$what is not supported yet.')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(authControllerProvider).savedAccounts;
    final activeId = ref.watch(authControllerProvider).account?.id;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 30),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(Routes.login),
        ),
        title: const Text('Accounts'),
      ),
      floatingActionButton: _AddAccountButton(
        onTap: () => context.push(Routes.xtreamLogin),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              children: [
                const _Tab(label: 'Xtream List', selected: true),
                const SizedBox(width: Insets.md),
                _Tab(
                  label: 'M3u Playlist',
                  selected: false,
                  onTap: () => _notSupported('M3U playlist'),
                ),
                const SizedBox(width: Insets.md),
                _Tab(
                  label: 'Single Channel',
                  selected: false,
                  onTap: () => _notSupported('Single channel'),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.md),
          Expanded(
            child: accounts.isEmpty
                ? EmptyState(
                    icon: Icons.cast_connected_rounded,
                    title: 'No Accounts Yet',
                    message: 'Add an Xtream playlist to get started.',
                    action: FilledButton(
                      onPressed: () => context.push(Routes.xtreamLogin),
                      child: const Text('Add Xtream playlist'),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                        Insets.lg, 0, Insets.lg, Insets.xxl * 3),
                    itemCount: accounts.length,
                    itemBuilder: (context, i) {
                      final account = accounts[i];
                      return _AccountCard(
                        account: account,
                        isActive: account.id == activeId,
                        isBusy: account.id == _busyAccountId,
                        onTap: () => _use(account),
                        onRemove: () => _remove(account),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        focusColor: AppColors.accentSoft,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            border: selected
                ? null
                : Border.all(color: AppColors.divider, width: 1.2),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : AppColors.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({
    required this.account,
    required this.isActive,
    required this.isBusy,
    required this.onTap,
    required this.onRemove,
  });

  final Account account;
  final bool isActive;
  final bool isBusy;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  static String _grouped(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    // Rebuild when a summary is recorded for any account.
    ref.watch(accountSummaryRevisionProvider);
    final summary = ref.read(accountSummaryStoreProvider).of(account.id);
    final streams = summary?.streamCount;

    final initial =
        (account.name.isEmpty ? '?' : account.name.characters.first)
            .toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: InkWell(
          onTap: isBusy ? null : onTap,
          onLongPress: isBusy ? null : onRemove,
          borderRadius: BorderRadius.circular(Radii.lg),
          focusColor: AppColors.accentSoft,
          child: Container(
            padding: const EdgeInsets.all(Insets.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.lg),
              border: isActive
                  ? Border.all(color: AppColors.accent, width: 1.4)
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Radii.md),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF1F3A2E), Color(0xFF12201A)],
                        ),
                      ),
                      child: Text(
                        initial,
                        style: text.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: Insets.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: Insets.xs),
                          Text(
                            account.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            account.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Insets.md, vertical: Insets.sm),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: Column(
                        children: [
                          const Text(
                            'STREAMS',
                            style: TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.9,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            // Never invented: until this account's catalogue
                            // has actually been loaded we show a dash.
                            streams == null ? '—' : _grouped(streams),
                            style: text.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.md),
                Row(
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: Insets.md, vertical: Insets.sm),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.link_rounded,
                                size: 15, color: AppColors.textTertiary),
                            const SizedBox(width: Insets.sm),
                            Flexible(
                              child: Text(
                                account.url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (isBusy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (isActive)
                      const Text(
                        'Signed in',
                        style: TextStyle(
                            color: AppColors.success,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Crimson "+" with the dashed ring from the reference.
class _AddAccountButton extends StatelessWidget {
  const _AddAccountButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Material(
        color: AppColors.accent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          focusColor: Colors.white24,
          child: CustomPaint(
            painter: _DashedRingPainter(),
            child: const Center(
              child: Icon(Icons.add_rounded, color: Colors.white, size: 26),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    final radius = size.width / 2 - 9;
    final center = Offset(size.width / 2, size.height / 2);
    const dashes = 18;
    const sweep = 6.283185307179586 / dashes;
    for (var i = 0; i < dashes; i++) {
      final start = i * sweep;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep * 0.55,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
