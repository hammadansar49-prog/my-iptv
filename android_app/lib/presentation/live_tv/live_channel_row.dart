import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/epg.dart';
import '../../data/models/library.dart';
import '../providers.dart';
import '../widgets/network_artwork.dart';

/// One channel row: logo, name, and the now/next guide line.
///
/// The guide is fetched per visible row and cached in the repository, so
/// scrolling a 15,000-channel list does not fan out thousands of requests —
/// only the rows the user actually looks at ask, and each answer is reused
/// for [Limits.epgTtl].
class LiveChannelRow extends ConsumerStatefulWidget {
  const LiveChannelRow({
    super.key,
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final LiveChannel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<LiveChannelRow> createState() => _LiveChannelRowState();
}

class _LiveChannelRowState extends ConsumerState<LiveChannelRow> {
  ChannelGuide? _guide;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    // Deferred by a frame so a fast scroll does not fire a request for every
    // row that flies past.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadGuide());
  }

  Future<void> _loadGuide() async {
    if (_requested || !mounted) return;
    _requested = true;
    final repo = ref.read(contentRepositoryProvider);
    if (repo == null) return;
    try {
      final guide = await repo.guideFor(widget.channel);
      if (!mounted) return;
      setState(() => _guide = guide);
    } catch (_) {
      // No guide is a normal state, not an error worth showing.
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final guide = _guide;
    final now = guide?.now;
    final isFavorite =
        ref.watch(favoritesProvider(ContentSection.live)).any(
              (f) => f.key == widget.channel.key,
            );

    return Material(
      color: widget.selected ? AppColors.surfaceHigh : Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        focusColor: AppColors.accentSoft,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg, vertical: Insets.sm),
          child: Row(
            children: [
              if (widget.selected)
                Container(
                  width: 3,
                  height: 40,
                  margin: const EdgeInsets.only(right: Insets.md),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              NetworkArtwork(
                url: widget.channel.logo,
                width: 52,
                height: 40,
                fit: BoxFit.contain,
                fallbackIcon: Icons.live_tv_rounded,
                fallbackLabel: widget.channel.name,
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (now != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        now.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                      const SizedBox(height: 3),
                      // Progress is computed locally from the clock, never
                      // polled (spec §45).
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: now.progressAt(DateTime.now()),
                          minHeight: 2,
                          backgroundColor: AppColors.divider,
                          valueColor: const AlwaysStoppedAnimation(
                              AppColors.accent),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: () => ref
                    .read(libraryRepositoryProvider)
                    .toggleFavorite(FavoriteEntry(
                      key: widget.channel.key,
                      section: ContentSection.live,
                      title: widget.channel.name,
                      refId: '${widget.channel.streamId}',
                      thumb: widget.channel.logo,
                      addedAt: DateTime.now(),
                    )),
                icon: Icon(
                  isFavorite ? Icons.favorite_rounded : Icons.favorite_border,
                  size: 20,
                  color:
                      isFavorite ? AppColors.accent : AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
