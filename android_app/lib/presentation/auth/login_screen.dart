import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/account.dart';
import '../widgets/error_banner.dart';
import 'auth_controller.dart';

/// "Add Xtream Account" — the credential form, laid out after the supplied
/// reference: close button, heading, four icon-led fields with small caps
/// labels, a glowing red Connect button and a note on where credentials live.
///
/// On success it hands off to the catalogue loading screen, which really
/// downloads the account's content before landing on Accounts.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  static const _bg = Color(0xFF151516);

  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider.notifier).loadSavedAccounts();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final ok = await ref.read(authControllerProvider.notifier).signIn(
          name: _name.text,
          url: _url.text,
          username: _username.text,
          password: _password.text,
        );
    if (!mounted || !ok) return;
    // Credentials verified: load the catalogue for real, then show the new
    // account on the Accounts screen.
    context.go(Routes.catalogLoading, extra: Routes.accounts);
  }

  Future<void> _pasteUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _url.text = text;
    _url.selection = TextSelection.collapsed(offset: text.length);
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.login);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: state.isBusy,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: _CloseButton(onTap: _close),
              ),
              const SizedBox(height: 22),
              const Text(
                'Add Xtream Account',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Connect your IPTV provider to start streaming live '
                'channels, movies, and series.',
                style: TextStyle(
                  color: Color(0xFF9A9A9F),
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 26),
              if (state.error != null) ...[
                ErrorBanner(
                  message: state.error!.message,
                  onDismiss:
                      ref.read(authControllerProvider.notifier).clearError,
                ),
                const SizedBox(height: 16),
              ],
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    _Field(
                      icon: Icons.sell_rounded,
                      label: 'PLAYLIST NAME',
                      hint: 'Enter playlist name',
                      controller: _name,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    _Field(
                      icon: Icons.person_rounded,
                      label: 'USERNAME',
                      hint: 'Enter username',
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'Enter your username'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    _Field(
                      icon: Icons.lock_rounded,
                      label: 'PASSWORD',
                      hint: 'Enter password',
                      controller: _password,
                      obscure: _obscure,
                      textInputAction: TextInputAction.next,
                      trailing: _TrailingIcon(
                        icon: _obscure
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        onTap: () => setState(() => _obscure = !_obscure),
                      ),
                      validator: (v) =>
                          (v ?? '').isEmpty ? 'Enter your password' : null,
                    ),
                    const SizedBox(height: 16),
                    _Field(
                      icon: Icons.language_rounded,
                      label: 'SERVER URL',
                      hint: 'http://your-iptv-server.com',
                      controller: _url,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      trailing: _TrailingIcon(
                        icon: Icons.content_paste_rounded,
                        tooltip: 'Paste',
                        onTap: _pasteUrl,
                      ),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Enter your server URL';
                        final uri = Uri.tryParse(Account.normaliseUrl(t));
                        if (uri == null || uri.host.isEmpty) {
                          return 'That does not look like a valid URL';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              _GlowButton(
                label: 'Connect Account',
                busy: state.isBusy,
                onTap: _submit,
              ),
              const SizedBox(height: 18),
              const Row(
                children: [
                  Icon(Icons.shield_rounded, size: 15, color: Color(0xFF7C7C80)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your credentials are encrypted and stored only on this device.',
                      style: TextStyle(color: Color(0xFF7C7C80), fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

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

/// A rounded card holding an icon, a small-caps label and the input itself.
/// The whole card is the tap target, and it outlines in the accent colour
/// while focused.
class _Field extends StatefulWidget {
  const _Field({
    required this.icon,
    required this.label,
    required this.hint,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.trailing,
    this.validator,
  });

  final IconData icon;
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;
  final FormFieldValidator<String>? validator;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
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
                    obscureText: widget.obscure,
                    keyboardType: widget.keyboardType,
                    textInputAction: widget.textInputAction,
                    onFieldSubmitted: widget.onSubmitted,
                    autocorrect: false,
                    enableSuggestions: !widget.obscure,
                    validator: widget.validator,
                    cursorColor: AppColors.accent,
                    style: const TextStyle(color: Colors.white, fontSize: 17),
                    decoration: InputDecoration(
                      hintText: widget.hint,
                      hintStyle: const TextStyle(
                        color: Color(0xFF6E6E73),
                        fontSize: 17,
                      ),
                      filled: false,
                      isDense: true,
                      contentPadding: const EdgeInsets.only(top: 6, bottom: 4),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      errorStyle: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
      ),
    );
  }
}

class _TrailingIcon extends StatelessWidget {
  const _TrailingIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, color: const Color(0xFFD1D1D6), size: 26),
    );
  }
}

class _GlowButton extends StatelessWidget {
  const _GlowButton({
    required this.label,
    required this.busy,
    required this.onTap,
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
