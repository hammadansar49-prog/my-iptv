import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// A 4-digit PIN prompt. Returns the entered PIN, or null if cancelled.
/// Shared by [SecurityScreen] (set/confirm/change/disable) and the lock
/// screen itself, so there is exactly one place that defines what a PIN
/// looks like (4 digits).
Future<String?> showPinDialog(BuildContext context, {required String title}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surfaceHigh,
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(4),
        ],
        style: const TextStyle(fontSize: 22, letterSpacing: 8),
        textAlign: TextAlign.center,
        decoration: const InputDecoration(counterText: ''),
        onSubmitted: (v) {
          if (v.length == 4) Navigator.of(context).pop(v);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, _) => TextButton(
            onPressed: value.text.length == 4
                ? () => Navigator.of(context).pop(value.text)
                : null,
            child: const Text('OK'),
          ),
        ),
      ],
    ),
  );
}
