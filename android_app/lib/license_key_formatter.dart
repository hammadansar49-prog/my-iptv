import 'package:flutter/services.dart';

final _nonKeyChars = RegExp(r'[^A-Z0-9]');

/// Live-formats whatever's typed or pasted into a license key box to match
/// the shape the admin panel actually generates (`MYIPTV-XXXXXX-XXXXXX-XXXXXX`
/// — see generateKey() in theottdeals' admin-iptv.js): uppercased, dashes
/// stripped out of anything the user pasted (with or without its own
/// dashes/spaces) and reinserted every 6 characters, capped at the key's
/// real length (4 groups of 6 = 24 characters + 3 dashes).
class LicenseKeyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    // Nothing actually changed (formatEditUpdate can fire from things other
    // than a real keystroke, e.g. focus/selection churn) — returning the
    // formatted value unconditionally here was forcing the cursor to the end
    // on every call, which some keyboards (seen on this OppoColorOS build)
    // fight with their own predictive-text/selection handling and can stall
    // on — this was the likely cause of an ANR reported while typing a key.
    if (newValue.text == oldValue.text) return newValue;
    final raw = newValue.text.toUpperCase().replaceAll(_nonKeyChars, '');
    final limited = raw.length > 24 ? raw.substring(0, 24) : raw;
    final buffer = StringBuffer();
    for (var i = 0; i < limited.length; i++) {
      if (i != 0 && i % 6 == 0) buffer.write('-');
      buffer.write(limited[i]);
    }
    final formatted = buffer.toString();
    // Already exactly right (the common case: typing the next character of
    // an already-well-formed key) — return the original value untouched so
    // the selection/cursor isn't reset for no reason.
    if (formatted == newValue.text) return newValue;
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}
