import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../services/player/player_controller.dart';

/// Makes a text field usable with an Android TV remote.
///
/// On TV, once a text field has focus the keyboard connection (IME) takes
/// the remote's keys: OK did nothing and Up/Down just moved the cursor, so
/// the focus was stuck in the field. Here the field is first a plain
/// focusable box — the remote moves on and off it freely — and only OK (or
/// a click) turns it into a live text field with the keyboard. Submitting
/// or leaving it hands the focus back to the box.
///
/// Phones get the field exactly as before.
class TvTextGate extends StatefulWidget {
  const TvTextGate({
    super.key,
    required this.builder,
    this.radius = 14,
  });

  /// Build the field with this focus node; call `done` on submit.
  final Widget Function(FocusNode node, VoidCallback done) builder;
  final double radius;

  @override
  State<TvTextGate> createState() => _TvTextGateState();
}

class _TvTextGateState extends State<TvTextGate> {
  final _gate = FocusNode(debugLabel: 'TvTextGate');
  final _text = FocusNode(debugLabel: 'TvTextGate.text');
  bool _editing = false;

  bool get _tv => PlayerController.tvMode;

  @override
  void initState() {
    super.initState();
    if (_tv) _text.canRequestFocus = false;
    _gate.addListener(_rebuild);
    _text.addListener(_onText);
  }

  @override
  void dispose() {
    _gate.dispose();
    _text.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _start() {
    if (_editing) return;
    setState(() => _editing = true);
    _text.canRequestFocus = true;
    _text.requestFocus();
  }

  void _stop() {
    if (!_editing) return;
    setState(() => _editing = false);
    _text.canRequestFocus = false;
    // Back on the box, so the remote can move up/down from here.
    if (!_gate.hasFocus) _gate.requestFocus();
  }

  void _onText() {
    if (_tv && _editing && !_text.hasFocus) _stop();
  }

  void _done() {
    if (_tv) {
      _text.unfocus();
      _stop();
    }
  }

  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  Widget build(BuildContext context) {
    final field = widget.builder(_text, _done);
    if (!_tv) return field;

    final highlighted = _gate.hasFocus && !_editing;
    return Focus(
      focusNode: _gate,
      onKeyEvent: (node, event) {
        if (!_editing &&
            event is KeyDownEvent &&
            _okKeys.contains(event.logicalKey)) {
          _start();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _start,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            border: highlighted
                ? Border.all(color: AppColors.accent, width: 2.5)
                : null,
          ),
          // Taps go to the gate until editing starts.
          child: IgnorePointer(ignoring: !_editing, child: field),
        ),
      ),
    );
  }
}
