import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pip_service.dart';
import 'player_controller.dart';

/// Picture-in-Picture for the inline live players (Live TV and EPG screens),
/// mirroring what player_screen.dart does for movies: a PiP button, auto-PiP
/// on Home while a channel plays, video-only rendering inside the window,
/// and closing the window (X) stops the channel and frees the connection.
mixin LivePipMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The screen's inline player, or null before a channel is picked.
  PlayerController? get pipPlayer;

  bool pipSupported = false;
  bool inPip = false;

  /// Whether this screen's player is the one PiP belongs to. The movie
  /// player and the always-alive EPG tab share the single PiP window.
  bool get ownsPip => PipService.onDismissed == _onPipDismissed;

  void initLivePip() {
    PipService.inPip.addListener(_onPipChanged);
    unawaited(PipService.isSupported().then((ok) {
      if (mounted) setState(() => pipSupported = ok);
    }));
  }

  void disposeLivePip() {
    PipService.inPip.removeListener(_onPipChanged);
    if (PipService.onDismissed == _onPipDismissed) {
      PipService.onDismissed = null;
    }
    unawaited(PipService.configure(autoEnter: false));
  }

  double get _aspect => pipPlayer?.displayAspect ?? 16 / 9;

  /// Call from the player listener: auto-enter only while really playing.
  void syncLivePip() {
    if (!pipSupported) return;
    final phase = pipPlayer?.state.phase;
    final playing =
        phase == PlaybackPhase.playing || phase == PlaybackPhase.buffering;
    if (playing) PipService.onDismissed = _onPipDismissed;
    if (!ownsPip) return;
    unawaited(PipService.configure(autoEnter: playing, aspect: _aspect));
  }

  Future<void> enterLivePip() async {
    PipService.onDismissed = _onPipDismissed;
    Navigator.of(context).popUntil((route) => route is! PopupRoute);
    await PipService.enter(aspect: _aspect);
  }

  void _onPipChanged() {
    if (!mounted) return;
    final now = PipService.inPip.value && ownsPip;
    if (now != inPip) setState(() => inPip = now);
  }

  void _onPipDismissed() {
    unawaited(pipPlayer?.stop());
    if (mounted) setState(() => inPip = false);
  }

  /// The PiP button for the video overlay (empty when unsupported/idle).
  Widget livePipButton({required bool hasMedia}) {
    if (!pipSupported || !hasMedia) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Picture in picture',
      onPressed: enterLivePip,
      icon: const Icon(
        Icons.picture_in_picture_alt_rounded,
        color: Colors.white,
      ),
    );
  }
}
