import 'package:flutter/material.dart';
import 'tv_text_gate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../providers.dart';

/// Horizontal category chips shared by Live TV, Movies and Series.
///
/// Deliberately its own widget so selecting a category rebuilds only the
/// strip and the list that watches the selection — not the whole screen
/// (spec §6: avoid unnecessary rebuilds).
class CategoryStrip extends ConsumerWidget {
  const CategoryStrip({super.key, required this.section});

  final ContentSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(categoriesProvider(section));
    final selected = ref.watch(selectedCategoryProvider(section));

    return async.maybeWhen(
      data: (categories) {
        if (categories.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: Insets.sm),
            itemBuilder: (context, i) {
              final category = categories[i];
              final isSelected = category.id == selected;
              return ChoiceChip(
                label: Text(category.name),
                selected: isSelected,
                showCheckmark: false,
                backgroundColor: AppColors.surface,
                selectedColor: AppColors.accent,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : AppColors.textPrimary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
                side: BorderSide.none,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                onSelected: (_) =>
                    ref.read(selectedCategoryProvider(section).notifier).state =
                        category.id,
              );
            },
          ),
        );
      },
      orElse: () => const SizedBox(height: 44),
    );
  }
}

/// Search field used by every scoped search (spec §18). It never decides
/// WHAT to search — the owning screen does that, which is what keeps the
/// scoping honest.
class ScopedSearchField extends StatelessWidget {
  const ScopedSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.md,
        Insets.lg,
        Insets.sm,
      ),
      // TV remote: see TvTextGate — OK starts typing, Up/Down move on.
      child: TvTextGate(
        builder: (node, done) => TextField(
          controller: controller,
          focusNode: node,
          onChanged: onChanged,
          onSubmitted: (_) => done(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: AppColors.textSecondary,
              size: 20,
            ),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: AppColors.textSecondary,
                    onPressed: onClear,
                  ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.md,
            ),
          ),
        ),
      ),
    );
  }
}

/// Poster grid skeleton (spec §41).
class PosterGridSkeleton extends StatelessWidget {
  const PosterGridSkeleton({super.key, this.columns = 3});

  final int columns;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(Insets.lg),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 0.62,
        crossAxisSpacing: Insets.md,
        mainAxisSpacing: Insets.lg,
      ),
      itemCount: columns * 4,
      itemBuilder: (context, _) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    );
  }
}
