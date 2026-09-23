import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
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
      builder: (context, child) {
        // Lock text scaling: a user with huge system text must not break the
        // EPG grid or the player controls (spec §39/§45). On narrow phones
        // (the 360dp test handset) text also shrinks with the screen width —
        // layouts were designed at ~375-390dp and rows of cards/pills
        // overflowed the edge on anything narrower.
        final media = MediaQuery.of(context);
        final narrow = isTv
            ? 1.0
            : (media.size.shortestSide / 375).clamp(0.85, 1.0);
        final system = media.textScaler.scale(1).clamp(0.9, isTv ? 1.1 : 1.1);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(system * narrow),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

final routerProvider = Provider<GoRouter>((ref) => buildRouter(ref));
