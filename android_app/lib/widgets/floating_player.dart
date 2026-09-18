import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_state.dart';
import '../screens/player_screen.dart';

/// The single floating player mounted once at the app root (see the
/// MaterialApp `builder:` in main.dart). Reads AppState.playerLaunch /
/// playerMini and mounts PlayerScreen either full-screen or as a small
/// draggable PiP box — always the SAME PlayerScreen widget (same GlobalKey,
/// same underlying Player/connection), so toggling mini <-> full never
/// tears anything down or reconnects. That's the whole point: it's what
/// fixes "shrinking/expanding shows loading again" and is what lets
/// playback keep running while the user browses Home/EPG/Downloads/Profile
/// or anything pushed on top of them.
class FloatingPlayer extends StatelessWidget {
  final AppState state;
  const FloatingPlayer({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerLaunch?>(
      valueListenable: state.playerLaunch,
      builder: (context, launch, _) {
        if (launch == null) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: state.playerMini,
          builder: (context, mini, __) {
            // PlayerScreen uses a GlobalKey so its State (and the underlying
            // media_kit Player/connection) survives across rebuilds — only
            // didUpdateWidget fires when mini changes, never a full
            // dispose+initState.  The Navigator wrapping provides the Overlay
            // that PlayerScreen's bottom sheets / popups need.
            final player = PlayerScreen(
              key: launch.playerKey,
              state: state,
              request: launch.request,
              favSection: launch.favSection,
              favItem: launch.favItem,
              mini: mini,
            );
            final wrapped = Navigator(
              onGenerateRoute: (settings) => PageRouteBuilder(
                opaque: false,
                pageBuilder: (context, animation, secondaryAnimation) => player,
              ),
            );
            if (!mini) return Positioned.fill(child: wrapped);
            return _DraggableMini(
              onExpand: () { state.playerMini.value = false; },
              child: wrapped,
            );
          },
        );
      },
    );
  }
}

/// A small (160x90) box the user can drag anywhere on screen while a video
/// plays mini. Position is local UI state only — it intentionally resets to
/// the bottom-right corner each time mini mode is re-entered rather than
/// being persisted anywhere.
class _DraggableMini extends StatefulWidget {
  final Widget child;
  final VoidCallback onExpand;
  const _DraggableMini({required this.child, required this.onExpand});

  @override
  State<_DraggableMini> createState() => _DraggableMiniState();
}

class _DraggableMiniState extends State<_DraggableMini> {
  Offset? _topLeft;
  static const _w = 160.0;
  static const _h = 90.0;
  static const _margin = 12.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxX = (constraints.maxWidth - _w - _margin).clamp(_margin, double.infinity);
        final maxY = (constraints.maxHeight - _h - _margin).clamp(_margin, double.infinity);
        _topLeft ??= Offset(maxX, maxY);
        final pos = Offset(_topLeft!.dx.clamp(_margin, maxX), _topLeft!.dy.clamp(_margin, maxY));
        return Positioned(
          left: pos.dx,
          top: pos.dy,
          width: _w,
          height: _h,
          child: Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) {
                widget.onExpand();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              onPanUpdate: (d) => setState(() => _topLeft = pos + d.delta),
              child: Material(
                elevation: 10,
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
