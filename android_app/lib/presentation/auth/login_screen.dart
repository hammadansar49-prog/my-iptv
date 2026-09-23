import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/account.dart';
import '../widgets/error_banner.dart';
import 'auth_controller.dart';

/// Xtream login plus the saved-playlist list, modelled on the "Accounts"
/// screen in the design reference: segmented tabs at the top, account cards
/// below, an accent action button.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    // Saved accounts are loaded by the splash, but a direct arrival (sign
    // out, deep link) needs them too.
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
    if (!mounted) return;
    // The credentials are verified at this point. Land on Accounts rather
    // than Home so the new playlist is shown in the switcher alongside any
    // others, which is where the user picks what to actually open.
    if (ok) context.go(Routes.accounts);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: state.isBusy,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.xl,
              Insets.lg,
              Insets.xxl,
            ),
            children: [
              Text('Xtream List', style: text.displaySmall),
              const SizedBox(height: Insets.xs),
              Text(
                'Add your playlist (via XC API).',
                style: text.bodyMedium,
              ),
              const SizedBox(height: Insets.xl),

              if (state.error != null) ...[
                ErrorBanner(
                  message: state.error!.message,
                  onDismiss:
                      ref.read(authControllerProvider.notifier).clearError,
                ),
                const SizedBox(height: Insets.lg),
              ],

              Text('Add an Xtream playlist', style: text.titleMedium),
              const SizedBox(height: Insets.md),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Playlist name (optional)',
                      ),
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Server URL (http://example.com:8080)',
                      ),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Enter your server URL';
                        final normalised = Account.normaliseUrl(t);
                        final uri = Uri.tryParse(normalised);
                        if (uri == null || uri.host.isEmpty) {
                          return 'That does not look like a valid URL';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      controller: _username,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(hintText: 'Username'),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'Enter your username'
                          : null,
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        hintText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            color: AppColors.textSecondary,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v ?? '').isEmpty ? 'Enter your password' : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Insets.xl),
              FilledButton(
                onPressed: state.isBusy ? null : _submit,
                child: state.isBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
