import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../presentation/iptv_live/iptv_live_layer.dart';
import '../presentation/providers.dart';
import 'router.dart';

class TheOttDealsApp extends ConsumerWidget {
  const TheOttDealsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTv = ref.watch(isTvProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'MY IPTV',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(tv: isTv),
      darkTheme: AppTheme.build(tv: isTv),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      // TV boxes often come with a mouse: let a left-button drag scroll
      // lists the way a finger does (Flutter only allows touch by default).
      scrollBehavior: const _AppScrollBehavior(),
      builder: (context, child) {
        // Lock text scaling: a user with huge system text must not break the
        // EPG grid or the player controls (spec §39/§45). On narrow phones
        // (the 360dp test handset) text also shrinks with the screen width —
        // layouts were designed at ~375-390dp and rows of cards/pills
        // overflowed the edge on anything narrower.
        // Inside the TV canvas, so it reads the scaled MediaQuery.
        final inner = Builder(
          builder: (context) {
            final media = MediaQuery.of(context);
            final narrow = isTv
                ? 1.0
                : (media.size.shortestSide / 375).clamp(0.85, 1.0);
            final system = media.textScaler
                .scale(1)
                .clamp(0.9, isTv ? 1.1 : 1.1);
            final content = MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(system * narrow),
              ),
              // Announcements, the licence block and update prompts render
              // above the Navigator so they cover every route, fullscreen
              // player included.
              child: IptvLiveLayer(child: child ?? const SizedBox.shrink()),
            );
            return content;
          },
        );
        // Right mouse button = Back, like the remote's Back key (dialogs,
        // keyboard, then the previous screen — PopScope rules apply).
        final withMouseBack = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            if (e.kind == PointerDeviceKind.mouse &&
                (e.buttons & kSecondaryMouseButton) != 0) {
              final focus = FocusManager.instance.primaryFocus;
              if (focus?.context?.widget is EditableText) {
                focus!.unfocus(); // closes the keyboard first
              } else {
                router.routerDelegate.navigatorKey.currentState?.maybePop();
              }
            }
          },
          child: inner,
        );
        return isTv ? _TvCanvas(child: withMouseBack) : withMouseBack;
      },
    );
  }
}

final routerProvider = Provider<GoRouter>((ref) => buildRouter(ref));

/// Android TV: lay the whole app out on a larger logical canvas and scale it
/// down to the screen. A 1080p box reports ~1280dp, which made every screen
/// (built from phone proportions) look blown up — one row of posters, a
/// hero that filled the TV. Laying out at [_width] shows ~25% more of
/// everything while keeping the same design; touch, focus and the keyboard
/// inset are scaled with it.
class _TvCanvas extends StatelessWidget {
  const _TvCanvas({required this.child});

  final Widget child;

  static const _width = 2048.0;
  static const _overscan = EdgeInsets.fromLTRB(48, 24, 48, 28);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    if (size.width <= 0 || size.width >= _width) return child;
    final scale = size.width / _width;
    final canvas = Size(_width, size.height / scale);
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: canvas,
        child: MediaQuery(
          data: media.copyWith(
            size: canvas,
            devicePixelRatio: media.devicePixelRatio * scale,
            // TV overscan: many sets crop the picture edges, which hid the
            // bottom nav bar and made it hard to reach with a mouse. Every
            // SafeArea/extendBody inset honours this margin.
            padding: media.padding / scale + _overscan,
            viewPadding: media.viewPadding / scale + _overscan,
            viewInsets: media.viewInsets / scale,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        ...super.dragDevices,
        PointerDeviceKind.mouse,
      };
}
