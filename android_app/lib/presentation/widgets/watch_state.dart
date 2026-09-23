import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Red "WATCHED" mark for a title played to the end.
class WatchedMark extends StatelessWidget {
  const WatchedMark({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_rounded, size: 14, color: AppColors.accent),
        SizedBox(width: 3),
        Text(
          'WATCHED',
          style: TextStyle(
            color: AppColors.accent,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

/// Compact white "Resume" pill with bold black text, for a title stopped
/// part-way. Continues from the saved position.
class ResumePill extends StatelessWidget {
  const ResumePill({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Resume',
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(8, 6, 11, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, size: 16, color: Colors.black),
                SizedBox(width: 2),
                Text(
                  'Resume',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
