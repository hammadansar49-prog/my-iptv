import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../providers.dart';
import 'license_state.dart';

/// Licence-key input in the login screen's card style: icon, small-caps
/// label, accent outline while focused.
class LicenseKeyField extends StatefulWidget {
  const LicenseKeyField({
    super.key,
    required this.controller,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<LicenseKeyField> createState() => _LicenseKeyFieldState();
}

class _LicenseKeyFieldState extends State<LicenseKeyField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _focus.requestFocus,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F21),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: focused
                ? AppColors.accent.withValues(alpha: 0.8)
                : const Color(0xFF2E2E30),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.vpn_key_rounded,
                color: Color(0xFFBDBDC2), size: 22),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'LICENCE KEY',
                    style: TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                    ),
                  ),
                  TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    onSubmitted: widget.onSubmitted,
                    cursorColor: AppColors.accent,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      letterSpacing: 0.6,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'XXXX-XXXX-XXXX-XXXX',
                      hintStyle:
                          TextStyle(color: Color(0xFF6E6E73), fontSize: 17),
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.only(top: 6, bottom: 4),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The login screen's accent button with its soft glow.
class GlowButton extends StatelessWidget {
  const GlowButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onTap,
    this.height = 58,
  });

  final String label;
  final bool busy;
  final VoidCallback onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.45),
            blurRadius: 30,
            spreadRadius: 1,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: height,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline error text in the accent colour.
class LicenseErrorText extends StatelessWidget {
  const LicenseErrorText(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.error_outline_rounded,
              size: 17, color: AppColors.accent),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: AppColors.accent,
              fontSize: 13.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// Home header pill: yellow "FREE TRIAL HH:MM:SS" or red "PRO · 23 days"
/// (live countdown on the last day). Tap → Plans.
class LicenseBadge extends ConsumerStatefulWidget {
  const LicenseBadge({super.key});

  @override
  ConsumerState<LicenseBadge> createState() => _LicenseBadgeState();
}

class _LicenseBadgeState extends ConsumerState<LicenseBadge> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(licenseStatusProvider);
    if (!status.activeNow) return const SizedBox.shrink();

    final exp = status.expiresAt;
    final left = exp?.difference(DateTime.now());

    final String title;
    final String? detail;
    final Decoration decoration;
    final Color fg;
    if (status.isTrial) {
      title = 'FREE TRIAL';
      detail = left == null ? null : formatCountdown(left);
      fg = const Color(0xFF2B1D00);
      // Warm gold, not neon yellow: the flat #FFD60A plus a wide glow
      // bloomed against the dark header and read as a smudge.
      decoration = BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFE08A), Color(0xFFFFC23D), Color(0xFFF2A007)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF2A007).withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      );
    } else {
      title = 'PRO';
      if (left == null) {
        detail = null;
      } else if (left < const Duration(hours: 24)) {
        detail = formatCountdown(left);
      } else {
        final days = (left.inHours / 24).ceil();
        detail = '$days day${days == 1 ? '' : 's'}';
      }
      fg = Colors.white;
      decoration = BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF3D6E), AppColors.accent, Color(0xFFB0002F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.3),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      );
    }

    // Android TV: the countdown/days must be readable from the sofa, so
    // the whole badge (text and icon) is drawn larger there.
    final tv = ref.watch(isTvProvider);
    final badge = Semantics(
      button: true,
      label: '$title ${detail ?? ''}, view plans',
      child: GestureDetector(
        onTap: () => context.push(Routes.plans),
        // Two short lines (label over countdown) instead of one long one:
        // on a 360dp phone "FREE TRIAL 23:59:59" on one line did not fit
        // beside the title and was cut off mid-word.
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
          decoration: decoration,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                status.isTrial
                    ? Icons.bolt_rounded
                    : Icons.workspace_premium_rounded,
                size: tv ? 28 : 16,
                color: fg,
              ),
              const SizedBox(width: 4),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: fg,
                      fontSize: 8.5,
                      height: 1.1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!tv) return badge;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(1.9),
      ),
      child: IconTheme.merge(
        data: const IconThemeData(size: 28),
        child: badge,
      ),
    );
  }
}
