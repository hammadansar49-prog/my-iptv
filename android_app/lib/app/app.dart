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
      title: 'TheOttDeals',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(tv: isTv),
      darkTheme: AppTheme.build(tv: isTv),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (context, child) {
        // Lock text scaling: a user with huge system text must not break the
        // EPG grid or the player controls (spec §39/§45).
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(
              media.textScaler.scale(1).clamp(0.9, isTv ? 1.1 : 1.2),
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

final routerProvider = Provider<GoRouter>((ref) => buildRouter(ref));
