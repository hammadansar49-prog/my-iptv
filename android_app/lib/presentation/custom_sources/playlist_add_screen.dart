import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/errors/app_error.dart';
import '../widgets/error_banner.dart';
import 'custom_models.dart';
import 'custom_store.dart';
import 'custom_widgets.dart';

/// Add an M3U playlist by URL. URL-only: no file picker is a dependency of
/// this app, and adding one just for this was out of scope.
class PlaylistAddScreen extends ConsumerStatefulWidget {
  const PlaylistAddScreen({super.key});

  @override
  ConsumerState<PlaylistAddScreen> createState() => _PlaylistAddScreenState();
}

class _PlaylistAddScreenState extends ConsumerState<PlaylistAddScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final url = _url.text.trim();
    var name = _name.text.trim();
    if (name.isEmpty) name = Uri.tryParse(url)?.host ?? 'Playlist';
    try {
      final p = await ref
          .read(customPlaylistsProvider.notifier)
          .add(name: name, url: url);
      if (!mounted) return;
      // Replace this form with the playlist itself.
      context.pushReplacement(Routes.customPlaylist, extra: p.id);
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load that playlist.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: formBackground,
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: FormCloseButton(onTap: () => popOrSetup(context)),
              ),
              const SizedBox(height: 22),
              const FormHeader(
                title: 'Add M3U Playlist',
                subtitle: 'Paste the link to your .m3u / .m3u8 playlist. '
                    'It is downloaded once and kept on this device.',
              ),
              const SizedBox(height: 26),
              if (_error != null) ...[
                ErrorBanner(
                  message: _error!,
                  onDismiss: () => setState(() => _error = null),
                ),
                const SizedBox(height: 16),
              ],
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    FormFieldCard(
                      icon: Icons.sell_rounded,
                      label: 'PLAYLIST NAME',
                      hint: 'Enter playlist name',
                      controller: _name,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    FormFieldCard(
                      icon: Icons.language_rounded,
                      label: 'PLAYLIST URL',
                      hint: 'http://example.com/playlist.m3u',
                      controller: _url,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      pasteButton: true,
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Enter the playlist URL';
                        return isValidPlaylistUrl(t)
                            ? null
                            : 'Use an http or https link';
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              GlowButton(label: 'Add Playlist', busy: _busy, onTap: _submit),
            ],
          ),
        ),
      ),
    );
  }
}
