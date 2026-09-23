import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../services/player/playback_request.dart';
import '../license/license_state.dart';
import 'custom_models.dart';

/// Plays a user-added URL through the existing player — the same route,
/// single-player guard, PiP and tracks as every Xtream item.
///
/// Same licence rule as the Xtream path: without an active licence/trial
/// the user is sent to the existing licence screen instead. [returnTo] is
/// where that screen continues to once activated (it uses `go`).
void playCustom(
  BuildContext context,
  WidgetRef ref, {
  required String url,
  required String title,
  required String historyKey,
  String subtitle = '',
  String? thumb,
  required String returnTo,
}) {
  if (!ref.read(licenseStatusProvider).activeNow) {
    context.push(Routes.license, extra: returnTo);
    return;
  }
  context.push(
    Routes.player,
    extra: PlaybackRequest(
      url: url.trim(),
      title: title,
      subtitle: subtitle,
      thumb: thumb,
      isLive: isLiveUrl(url),
      historyKey: historyKey,
      section: sectionForUrl(url),
    ),
  );
}

/// The screens below are pushed; when opened cold (no back stack) fall back
/// to the setup screen rather than a dead end.
void popOrSetup(BuildContext context) =>
    context.canPop() ? context.pop() : context.go(Routes.login);

/// Background of the Add Xtream Account form, reused so the new forms match.
const formBackground = Color(0xFF151516);

/// Copies of the Add Xtream Account form's field/button/close visuals
/// (those are private to `login_screen.dart`, which is deliberately left
/// untouched).
class FormCloseButton extends StatelessWidget {
  const FormCloseButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Close',
      child: Material(
        color: const Color(0xFF2A2A2C),
        shape: const CircleBorder(side: BorderSide(color: Color(0xFF3A3A3C))),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: const SizedBox.square(
            dimension: 46,
            child: Icon(Icons.close_rounded, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

class FormHeader extends StatelessWidget {
  const FormHeader({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          style: const TextStyle(
            color: Color(0xFF9A9A9F),
            fontSize: 16,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class FormFieldCard extends StatefulWidget {
  const FormFieldCard({
    super.key,
    required this.icon,
    required this.label,
    required this.hint,
    required this.controller,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.validator,
    this.pasteButton = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;
  final bool pasteButton;

  @override
  State<FormFieldCard> createState() => _FormFieldCardState();
}

class _FormFieldCardState extends State<FormFieldCard> {
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

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    widget.controller.text = text;
    widget.controller.selection = TextSelection.collapsed(offset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _focus.requestFocus,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(20, 14, 10, 12),
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
            Icon(widget.icon, color: const Color(0xFFBDBDC2), size: 22),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                    ),
                  ),
                  TextFormField(
                    controller: widget.controller,
                    focusNode: _focus,
                    keyboardType: widget.keyboardType,
                    textInputAction: widget.textInputAction,
                    onFieldSubmitted: widget.onSubmitted,
                    autocorrect: false,
                    validator: widget.validator,
                    cursorColor: AppColors.accent,
                    style: const TextStyle(color: Colors.white, fontSize: 17),
                    decoration: const InputDecoration(
                      hintStyle:
                          TextStyle(color: Color(0xFF6E6E73), fontSize: 17),
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.only(top: 6, bottom: 4),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      errorStyle:
                          TextStyle(color: AppColors.accent, fontSize: 12),
                    ).copyWith(hintText: widget.hint),
                  ),
                ],
              ),
            ),
            if (widget.pasteButton)
              IconButton(
                onPressed: _paste,
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste_rounded,
                    color: Color(0xFFD1D1D6), size: 26),
              ),
          ],
        ),
      ),
    );
  }
}

class GlowButton extends StatelessWidget {
  const GlowButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final bool busy;
  final VoidCallback onTap;

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
            height: 58,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white),
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

/// Crimson round "+" used as the FAB on the list screens.
class AddFab extends StatelessWidget {
  const AddFab({super.key, required this.onTap, required this.tooltip});

  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 64,
        child: Material(
          color: AppColors.accent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}

Future<bool> confirmDelete(BuildContext context, String title, String body) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surfaceHigh,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete', style: TextStyle(color: AppColors.danger)),
        ),
      ],
    ),
  );
  return ok ?? false;
}
