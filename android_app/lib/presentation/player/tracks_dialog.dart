import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../services/player/player_controller.dart';

enum _Kind { video, audio, subtitle }

/// Video / Audio / Subtitle track picker, laid out after the reference:
/// categories on the left, a hairline, then "Disable" plus the stream's real
/// tracks with a check on the one playing. Only tracks the stream actually
/// has are listed — a film with no subtitles shows an empty Subtitle list.
Future<void> showTracksDialog(BuildContext context, PlayerController player) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close tracks',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 180),
    transitionBuilder: (context, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween(
          begin: 0.96,
          end: 1.0,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: child,
      ),
    ),
    pageBuilder: (context, _, __) => _TracksDialog(player: player),
  );
}

class _TracksDialog extends StatefulWidget {
  const _TracksDialog({required this.player});

  final PlayerController player;

  @override
  State<_TracksDialog> createState() => _TracksDialogState();
}

class _TracksDialogState extends State<_TracksDialog> {
  _Kind _kind = _Kind.audio;

  static const _panel = Color(0xFF161616);
  static const _line = Color(0xFF3A3A3A);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: (size.width * 0.5).clamp(320.0, 560.0),
          height: (size.height * 0.76).clamp(240.0, 420.0),
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 9,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 34),
                      child: Column(
                        children: [
                          for (final k in _Kind.values)
                            _CategoryTab(
                              label: switch (k) {
                                _Kind.video => 'Video Tracks',
                                _Kind.audio => 'Audio Tracks',
                                _Kind.subtitle => 'Subtitle Tracks',
                              },
                              selected: _kind == k,
                              onTap: () => setState(() => _kind = k),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: 28),
                    color: _line,
                  ),
                  Expanded(
                    flex: 11,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(22, 58, 22, 22),
                      child: _TrackList(
                        rows: _rows(),
                        onPicked: () => setState(() {}),
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 10,
                right: 10,
                child: IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Color(0xFF8E8E8E),
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_Row> _rows() {
    final p = widget.player;
    switch (_kind) {
      case _Kind.video:
        final tracks = p.videoTracks;
        if (tracks.isEmpty) return const [];
        final cur = p.currentVideoTrack?.id;
        return [
          _Row('Disable', cur == 'no', () => p.setVideoTrack(VideoTrack.no())),
          for (var i = 0; i < tracks.length; i++)
            _Row(
              _label(
                'Track ${i + 1}',
                tracks[i].title,
                null,
                extra: _res(tracks[i]),
              ),
              tracks[i].id == cur,
              () => p.setVideoTrack(tracks[i]),
            ),
        ];
      case _Kind.audio:
        final tracks = p.audioTracks;
        if (tracks.isEmpty) return const [];
        final cur = p.currentAudioTrack?.id;
        return [
          _Row('Disable', cur == 'no', () => p.setAudioTrack(AudioTrack.no())),
          for (var i = 0; i < tracks.length; i++)
            _Row(
              _label('Track ${i + 1}', tracks[i].title, tracks[i].language),
              tracks[i].id == cur,
              () => p.setAudioTrack(tracks[i]),
            ),
        ];
      case _Kind.subtitle:
        final tracks = p.subtitleTracks;
        // No subtitles in this stream: leave the list empty, as asked.
        if (tracks.isEmpty) return const [];
        final cur = p.currentSubtitleTrack?.id;
        return [
          _Row(
            'Disable',
            cur == 'no' || cur == null,
            () => p.setSubtitleTrack(SubtitleTrack.no()),
          ),
          for (var i = 0; i < tracks.length; i++)
            _Row(
              _label('Track ${i + 1}', tracks[i].title, tracks[i].language),
              tracks[i].id == cur,
              () => p.setSubtitleTrack(tracks[i]),
            ),
        ];
    }
  }

  static String? _res(VideoTrack t) =>
      (t.h != null && t.h! > 0) ? '${t.h}p' : null;

  /// "Track 1 · Hindi" — the language (or the stream's own title) is what
  /// actually tells two audio tracks apart.
  static String _label(
    String base,
    String? title,
    String? lang, {
    String? extra,
  }) {
    final parts = <String>[
      if (lang != null && lang.isNotEmpty) _language(lang),
      if (title != null && title.isNotEmpty && title != lang) title,
      if (extra != null) extra,
    ];
    return parts.isEmpty ? base : '$base · ${parts.join(' · ')}';
  }

  static String _language(String code) =>
      const {
        'hin': 'Hindi',
        'hi': 'Hindi',
        'eng': 'English',
        'en': 'English',
        'urd': 'Urdu',
        'ur': 'Urdu',
        'ara': 'Arabic',
        'ar': 'Arabic',
        'tam': 'Tamil',
        'ta': 'Tamil',
        'tel': 'Telugu',
        'te': 'Telugu',
        'mal': 'Malayalam',
        'ml': 'Malayalam',
        'kan': 'Kannada',
        'kn': 'Kannada',
        'ben': 'Bengali',
        'bn': 'Bengali',
        'pan': 'Punjabi',
        'pa': 'Punjabi',
        'mar': 'Marathi',
        'mr': 'Marathi',
        'tur': 'Turkish',
        'tr': 'Turkish',
        'spa': 'Spanish',
        'es': 'Spanish',
        'fre': 'French',
        'fra': 'French',
        'fr': 'French',
        'ger': 'German',
        'deu': 'German',
        'de': 'German',
        'ita': 'Italian',
        'it': 'Italian',
        'por': 'Portuguese',
        'pt': 'Portuguese',
        'rus': 'Russian',
        'ru': 'Russian',
        'jpn': 'Japanese',
        'ja': 'Japanese',
        'kor': 'Korean',
        'ko': 'Korean',
        'chi': 'Chinese',
        'zho': 'Chinese',
        'zh': 'Chinese',
        'per': 'Persian',
        'fas': 'Persian',
        'fa': 'Persian',
        'und': 'Unknown',
      }[code.toLowerCase()] ??
      code.toUpperCase();
}

class _Row {
  const _Row(this.label, this.selected, this.select);
  final String label;
  final bool selected;
  final Future<void> Function() select;
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 56,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 150),
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFFD8D8D8),
              fontSize: selected ? 19 : 18,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w300,
            ),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }
}

class _TrackList extends StatelessWidget {
  const _TrackList({required this.rows, required this.onPicked});

  final List<_Row> rows;
  final VoidCallback onPicked;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        return InkWell(
          onTap: () async {
            await r.select();
            // Give libmpv a beat to report the new selection before the
            // check mark moves.
            await Future<void>.delayed(const Duration(milliseconds: 120));
            onPicked();
          },
          child: Container(
            height: 56,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF3A3A3A))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    r.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 17),
                  ),
                ),
                if (r.selected)
                  const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
