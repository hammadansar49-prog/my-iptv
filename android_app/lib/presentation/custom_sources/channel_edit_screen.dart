import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import 'custom_models.dart';
import 'custom_store.dart';
import 'custom_widgets.dart';

/// Add / edit one Single Channel. Styled like the Add Xtream Account form.
class ChannelEditScreen extends ConsumerStatefulWidget {
  const ChannelEditScreen({super.key, this.existing});

  final CustomChannel? existing;

  @override
  ConsumerState<ChannelEditScreen> createState() => _ChannelEditScreenState();
}

class _ChannelEditScreenState extends ConsumerState<ChannelEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _url = TextEditingController(text: widget.existing?.url);
  late final _logo = TextEditingController(text: widget.existing?.logo);

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _logo.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final logo = _logo.text.trim();
    ref.read(customChannelsProvider.notifier).upsert(
          id: widget.existing?.id,
          name: _name.text.trim(),
          url: _url.text.trim(),
          logo: logo.isEmpty ? null : logo,
        );
    // Opened from the Setup/Accounts entry with nothing saved yet → land on
    // the list; opened from the list → just go back to it.
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.customChannels);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      backgroundColor: formBackground,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: FormCloseButton(onTap: () => popOrSetup(context)),
            ),
            const SizedBox(height: 22),
            FormHeader(
              title: editing ? 'Edit Channel' : 'Add Single Channel',
              subtitle: 'Play any live stream or video from a direct link '
                  '(http, https, rtmp or rtsp).',
            ),
            const SizedBox(height: 26),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  FormFieldCard(
                    icon: Icons.sell_rounded,
                    label: 'CHANNEL NAME',
                    hint: 'Enter channel name',
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                  ),
                  const SizedBox(height: 16),
                  FormFieldCard(
                    icon: Icons.link_rounded,
                    label: 'STREAM URL',
                    hint: 'http://example.com/stream.m3u8',
                    controller: _url,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    pasteButton: true,
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return 'Enter the stream URL';
                      return isValidStreamUrl(t)
                          ? null
                          : 'Use an http, https, rtmp or rtsp link';
                    },
                  ),
                  const SizedBox(height: 16),
                  FormFieldCard(
                    icon: Icons.image_rounded,
                    label: 'LOGO URL (OPTIONAL)',
                    hint: 'https://example.com/logo.png',
                    controller: _logo,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return null;
                      final u = Uri.tryParse(t);
                      return u != null &&
                              (u.scheme == 'http' || u.scheme == 'https') &&
                              u.host.isNotEmpty
                          ? null
                          : 'Use an http or https image link';
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            GlowButton(
              label: editing ? 'Save Channel' : 'Add Channel',
              onTap: _save,
            ),
          ],
        ),
      ),
    );
  }
}
