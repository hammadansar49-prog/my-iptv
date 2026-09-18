import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_state.dart';
import '../artwork.dart';
import '../license.dart';
import '../models.dart';
import '../theme.dart';
import '../xtream_client.dart';
import 'series_screen.dart';
import 'lists_screen.dart';
import 'live_tv_screen.dart';
import 'plans_sheet.dart';

const kPillSections = ['movies', 'series', 'live'];
const kPillLabels = {'movies': 'Movies', 'series': 'Series', 'live': 'Live TV'};

class HomeTab extends StatefulWidget {
  final AppState state;
  final LicenseService? license;
  const HomeTab({super.key, required this.state, this.license});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  late String section;
  String? categoryId;
  String search = '';

  List<Category> categories = [];
  bool catLoading = true;
  String? catError;

  List<PlayableItem> items = [];
  bool itemsLoading = true;
  String? itemsError;

  int renderedCount = 0;
  static const pageSize = 60;
  int heroIndex = 0;
  final scrollCtrl = ScrollController();
  final pageCtrl = PageController(viewportFraction: 1);
  final searchCtrl = TextEditingController();
  Timer? _heroAutoTimer;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    final pref = widget.state.defaultSection;
    section = kPillSections.contains(pref) ? pref : 'movies';
    scrollCtrl.addListener(() {
      if (scrollCtrl.hasClients && scrollCtrl.position.pixels > scrollCtrl.position.maxScrollExtent - 500) {
        _loadMore();
      }
    });
    _loadSection();
    _armHeroAutoplay();
    _armCountdownIfNeeded();
  }

  // The hero carousel (poster + Play/My List row at the top of Home) now
  // advances itself every few seconds instead of sitting still until the
  // user swipes it — same PageView/dots indicator as before, just driven by
  // this timer in addition to manual drags. Paused for a beat on any real
  // touch (see the ScrollNotification handling in _buildHero) so it doesn't
  // fight the user mid-swipe, and restarted after they let go.
  void _armHeroAutoplay() {
    _heroAutoTimer?.cancel();
    _heroAutoTimer = Timer.periodic(const Duration(seconds: 5), (_) => _advanceHero());
  }

  void _advanceHero() {
    if (!mounted || !pageCtrl.hasClients) return;
    final len = items.length.clamp(0, 15);
    if (len <= 1) return;
    final next = (heroIndex + 1) % len;
    pageCtrl.animateToPage(next, duration: const Duration(milliseconds: 650), curve: Curves.easeInOutCubic);
  }

  @override
  void dispose() {
    _heroAutoTimer?.cancel();
    _countdownTimer?.cancel();
    searchCtrl.dispose();
    pageCtrl.dispose();
    scrollCtrl.dispose();
    super.dispose();
  }

  // When < 1 hour remains, rebuild every second so the badge shows a live
  // h:mm:ss countdown instead of a static "1h".
  void _armCountdownIfNeeded() {
    _countdownTimer?.cancel();
    final license = widget.license;
    if (license == null) return;
    final status = license.localStatus();
    if (!status.valid) return;
    final msLeft = status.expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (msLeft <= 0 || msLeft > 3600000) return;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String get _cacheKey => '$section:${categoryId ?? 'all'}';

  Future<void> _loadSection() async {
    categoryId = null;
    heroIndex = 0;
    if (pageCtrl.hasClients) pageCtrl.jumpToPage(0);

    if (widget.state.catCache.containsKey(section)) {
      setState(() {
        categories = widget.state.catCache[section]!;
        catLoading = false;
        catError = null;
      });
    } else {
      setState(() {
        catLoading = true;
        catError = null;
      });
    }

    if (widget.state.itemCache.containsKey(_cacheKey)) {
      setState(() {
        items = widget.state.itemCache[_cacheKey]!;
        itemsLoading = false;
        itemsError = null;
        renderedCount = pageSize.clamp(0, items.length);
      });
    } else {
      setState(() {
        itemsLoading = true;
        itemsError = null;
        items = [];
        renderedCount = 0;
      });
    }

    final mySection = section;

    if (!widget.state.catCache.containsKey(section)) {
      widget.state.sectionCategories(mySection).then((cats) {
        if (!mounted || mySection != section) return;
        setState(() {
          categories = cats;
          catLoading = false;
        });
      }).catchError((e) {
        if (!mounted || mySection != section) return;
        setState(() {
          catLoading = false;
          catError = e is XtreamException ? e.message : 'Could not load categories.';
        });
      });
    }

    if (!widget.state.itemCache.containsKey(_cacheKey)) {
      try {
        final list = await widget.state.sectionItems(mySection);
        if (!mounted || mySection != section) return;
        setState(() {
          items = list;
          itemsLoading = false;
          renderedCount = pageSize.clamp(0, items.length);
        });
      } catch (e) {
        if (!mounted || mySection != section) return;
        setState(() {
          itemsLoading = false;
          itemsError = e is XtreamException ? e.message : 'Could not load $mySection.';
        });
      }
    }
  }

  Future<void> _loadCategoryItems(String? catId, {bool force = false}) async {
    final mySection = section;
    final key = '$mySection:${catId ?? 'all'}';
    if (!force && widget.state.itemCache.containsKey(key)) {
      setState(() {
        items = widget.state.itemCache[key]!;
        renderedCount = pageSize.clamp(0, items.length);
        itemsError = null;
      });
      return;
    }
    setState(() {
      itemsLoading = true;
      itemsError = null;
    });
    try {
      final list = await widget.state.sectionItems(mySection, categoryId: catId, force: force);
      if (!mounted || section != mySection) return;
      setState(() {
        items = list;
        itemsLoading = false;
        renderedCount = pageSize.clamp(0, items.length);
      });
    } catch (e) {
      if (!mounted || section != mySection) return;
      setState(() {
        itemsLoading = false;
        itemsError = e is XtreamException ? e.message : 'Could not load $mySection.';
      });
    }
  }

  void _loadMore() {
    if (renderedCount >= _filteredItems.length) return;
    setState(() => renderedCount = (renderedCount + pageSize).clamp(0, _filteredItems.length));
  }

  List<PlayableItem> get _filteredItems {
    if (search.isEmpty) return items;
    final q = search.toLowerCase();
    return items.where((it) => it.name.toLowerCase().contains(q)).toList();
  }

  void _selectSection(String s) {
    if (s == section) return;
    setState(() => section = s);
    _loadSection();
  }

  void _openCategoryPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: .6,
        minChildSize: .3,
        maxChildSize: .9,
        expand: false,
        builder: (context, scroll) => catLoading
            ? const Center(child: CircularProgressIndicator())
            : catError != null
                ? Center(child: Text(catError!, style: const TextStyle(color: AppColors.textDim)))
                : ListView(
                    controller: scroll,
                    children: [
                      ListTile(
                        title: const Text('All'),
                        selected: categoryId == null,
                        selectedTileColor: AppColors.bg3,
                        onTap: () {
                          Navigator.pop(context);
                          setState(() => categoryId = null);
                          _loadCategoryItems(null);
                        },
                      ),
                      ...categories.map((c) => ListTile(
                            title: Text(c.name, style: const TextStyle(fontSize: 13)),
                            selected: categoryId == c.id,
                            selectedTileColor: AppColors.bg3,
                            onTap: () {
                              Navigator.pop(context);
                              setState(() => categoryId = c.id);
                              _loadCategoryItems(c.id);
                            },
                          )),
                    ],
        ),
      ),
    );
  }

  // Debounced against a fast double-tap on a grid card: each branch pushes
  // a route or (for movies) reaches AppState.launchPlayer, and a rapid
  // second tap used to fire this whole method again before the first push
  // had registered, stacking two routes or — worse — two player launches
  // racing to construct/dispose the native player. A single tap still opens
  // instantly; a second tap within the window is dropped.
  DateTime? _lastOpenItem;

  Future<void> _openItem(PlayableItem it) async {
    final now = DateTime.now();
    if (_lastOpenItem != null && now.difference(_lastOpenItem!) < const Duration(milliseconds: 800)) return;
    _lastOpenItem = now;
    final client = widget.state.client;
    if (client == null) return;
    if (section == 'live') {
      // Live channels open the way YouTube plays a video: inline at the top
      // with the rest of the channels scrollable underneath, not straight
      // into a forced-landscape full player.
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => LiveTvScreen(state: widget.state, channels: _filteredItems, initial: it)));
    } else if (section == 'movies') {
      final url = client.vodUrl(it.id, ext: it.containerExt);
      _goToPlayer(PlayRequest(url: url, isLive: false, type: 'movie', title: it.name, subtitle: 'Movie', thumb: it.thumb, historyKey: 'movie:${it.id}'), favSection: 'movies', favItem: it);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(state: widget.state, series: it)));
    }
  }

  void _goToPlayer(PlayRequest req, {String? favSection, PlayableItem? favItem}) {
    final existing = widget.state.findHistory(req.historyKey);
    if (existing != null) req.resumeAt = existing.resumeAt;
    widget.state.launchPlayer(req, favSection: favSection, favItem: favItem);
  }

  @override
  Widget build(BuildContext context) {
    final hero = items.take(15).toList();
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AppColors.accent,
          onRefresh: () async {
            widget.state.itemCache.remove(_cacheKey);
            await _loadCategoryItems(categoryId, force: true);
          },
          child: CustomScrollView(
            controller: scrollCtrl,
            slivers: [
              SliverToBoxAdapter(child: _buildTopBar()),
              SliverToBoxAdapter(child: _buildPills()),
              if (hero.isNotEmpty && categoryId == null && search.isEmpty)
                SliverToBoxAdapter(child: _buildHero(hero)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 90),
                sliver: _buildGridSliver(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(gradient: const LinearGradient(colors: [AppColors.accent, AppColors.accent2]), borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: const Text('M', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Text('MY IPTV', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700))),
          if (widget.license != null) _buildProBadge(),
          IconButton(
            icon: const Icon(Icons.favorite, color: AppColors.accent),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListsScreen(state: widget.state, kind: ListsKind.favorites))),
          ),
        ],
      ),
    );
  }

  // Same logic as updateProBadge() in the PC app's renderer.js: shows "PRO"
  // normally, switches to a red/orange "PRO · Nd left" as the key/trial gets
  // close to expiring so the user notices before it lapses. Tapping it opens
  // the same Plans popup as the license gate's "See Plans", so upgrading
  // never requires logging out first.
  Widget _buildProBadge() {
    final status = widget.license!.localStatus();
    if (!status.valid) return const SizedBox.shrink();
    final msLeft = status.expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (msLeft <= 0) return const SizedBox.shrink();
    final daysLeft = (msLeft / 86400000).ceil();
    final warn = daysLeft <= 7;
    // Under 24h: show hours. Under 1h: live h:mm:ss countdown that ticks
    // every second (see _armCountdownIfNeeded which forces a rebuild).
    String timeLabel;
    if (msLeft < 3600000) {
      final totalSec = (msLeft / 1000).floor();
      final h = totalSec ~/ 3600;
      final m = (totalSec % 3600) ~/ 60;
      final s = totalSec % 60;
      timeLabel = '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';
    } else if (msLeft < 86400000) {
      timeLabel = '${(msLeft / 3600000).ceil().clamp(1, 23)}h';
    } else {
      timeLabel = '${daysLeft}d';
    }
    final label = status.isTrial
        ? (warn ? 'TRIAL · $timeLabel' : 'TRIAL')
        : (warn ? 'PRO · $timeLabel' : 'PRO');
    final color = warn ? const Color(0xFFEF4444) : AppColors.accent;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => showPlansSheet(context, widget.license!),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: color.withValues(alpha: .15), borderRadius: BorderRadius.circular(20), border: Border.all(color: color)),
          child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ),
      ),
    );
  }

  Widget _buildPills() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: searchCtrl,
            onChanged: (v) => setState(() => search = v),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true, hintText: 'Search...', prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: search.isEmpty ? null : IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () { searchCtrl.clear(); setState(() => search = ''); },
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              ...kPillSections.map((s) {
                final active = s == section;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(kPillLabels[s]!),
                    selected: active,
                    onSelected: (_) => _selectSection(s),
                    selectedColor: AppColors.accent,
                    backgroundColor: AppColors.bg2,
                    side: BorderSide(color: active ? AppColors.accent : AppColors.border),
                    labelStyle: TextStyle(color: active ? Colors.white : AppColors.textDim, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                );
              }),
              ActionChip(
                avatar: const Icon(Icons.filter_list, size: 16, color: AppColors.textDim),
                label: Text(categoryId == null ? 'Category' : (categories.firstWhere((c) => c.id == categoryId, orElse: () => Category(id: '', name: 'Category')).name)),
                onPressed: _openCategoryPicker,
                backgroundColor: AppColors.bg2,
                side: const BorderSide(color: AppColors.border),
                labelStyle: const TextStyle(color: AppColors.textDim, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildHero(List<PlayableItem> hero) {
    return SizedBox(
      height: 380,
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            // `dragDetails != null` is what tells a real finger-drag apart
            // from the animateToPage() call _advanceHero() itself makes
            // (that one reports null) — so this only pauses the autoplay
            // timer for an actual manual swipe, and only that swipe.
            onNotification: (n) {
              if (n is ScrollStartNotification && n.dragDetails != null) {
                _heroAutoTimer?.cancel();
              } else if (n is ScrollEndNotification && n.dragDetails != null) {
                _armHeroAutoplay();
              }
              return false;
            },
            child: PageView.builder(
            controller: pageCtrl,
            itemCount: hero.length,
            onPageChanged: (i) => setState(() => heroIndex = i),
            itemBuilder: (context, i) {
              final it = hero[i];
              return Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) {
                    _openItem(it);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: GestureDetector(
                onTap: () => _openItem(it),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Artwork(url: it.thumb, title: it.name, width: MediaQuery.of(context).size.width, fit: BoxFit.cover),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter, end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black.withValues(alpha: .85)],
                            stops: const [0.4, 1],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16, right: 16, bottom: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                            if (it.rating > 0) ...[
                              const SizedBox(height: 4),
                              Text('★ ${it.rating.toStringAsFixed(1)}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () => _openItem(it),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
                                  icon: const Icon(Icons.play_arrow, size: 18),
                                  label: const Text('Play'),
                                ),
                                const SizedBox(width: 10),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    try { await widget.state.toggleFavorite(section, it); } catch (_) {}
                                    if (!mounted) return;
                                    setState(() {});
                                  },
                                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                                  icon: Icon(widget.state.isFavorite(section, it) ? Icons.check : Icons.add, size: 18),
                                  label: const Text('My List'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              );
            },
            ),
          ),
          Positioned(
            bottom: 8, left: 0, right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(hero.length, (i) => Container(
                    width: i == heroIndex ? 16 : 5, height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(color: i == heroIndex ? AppColors.accent : Colors.white38, borderRadius: BorderRadius.circular(3)),
                  )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridSliver() {
    if (itemsLoading) {
      return const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
    }
    if (itemsError != null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: AppColors.textDim, size: 32),
            const SizedBox(height: 10),
            Text(itemsError!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: () => _loadCategoryItems(categoryId), child: const Text('Retry')),
          ]),
        ),
      );
    }
    final filtered = _filteredItems;
    if (filtered.isEmpty) {
      return const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('No items found.', style: TextStyle(color: AppColors.textDim))));
    }
    final shown = filtered.take(renderedCount).toList();
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: section == 'live' ? 220 : 150,
        childAspectRatio: section == 'live' ? 16 / 11 : 2 / 3.4,
        crossAxisSpacing: 10, mainAxisSpacing: 10,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => _ItemCard(item: shown[i], section: section, state: widget.state, onTap: () => _openItem(shown[i])),
        childCount: shown.length,
      ),
    );
  }
}

class _ItemCard extends StatefulWidget {
  final PlayableItem item;
  final String section;
  final AppState state;
  final VoidCallback onTap;
  const _ItemCard({required this.item, required this.section, required this.state, required this.onTap});

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  final _focusNode = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final faved = widget.state.isFavorite(widget.section, it);
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (f) { if (mounted) setState(() => _focused = f); },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _focused ? AppColors.accent : AppColors.border, width: _focused ? 2 : 1),
      ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Artwork(url: it.thumb, title: it.name, width: 150, fit: BoxFit.cover),
                  if (it.rating > 0) Positioned(top: 6, left: 6, child: _badge('★ ${it.rating.toStringAsFixed(1)}')),
                  Positioned(
                    top: 6, right: 6,
                    child: GestureDetector(
                      onTap: () async {
                        try { await widget.state.toggleFavorite(widget.section, it); } catch (_) {}
                        if (!mounted) return;
                        setState(() {});
                      },
                      child: Container(
                        width: 26, height: 26,
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55), shape: BoxShape.circle),
                        child: Icon(faved ? Icons.favorite : Icons.favorite_border, size: 14, color: faved ? const Color(0xFFFF5D7A) : Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _badge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(5)),
        child: Text(text, style: const TextStyle(fontSize: 10, color: Colors.white)),
      );
}
