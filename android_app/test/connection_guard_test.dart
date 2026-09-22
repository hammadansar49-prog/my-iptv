import 'package:flutter_test/flutter_test.dart';
import 'package:theottdeals/core/network/connection_guard.dart';

/// The one-connection constraint is the single most important invariant in
/// this app (CLAUDE.md). These tests pin the behaviour so a future refactor
/// cannot quietly reintroduce a second provider socket.
void main() {
  group('ConnectionGuard', () {
    test('defaults to a single connection', () {
      final guard = ConnectionGuard();
      expect(guard.maxConnections, 1);
      expect(guard.isBusy, isFalse);
    });

    test('a second acquire has to wait for the first to be released', () async {
      final guard = ConnectionGuard();
      final first = await guard.acquire(ProviderUse.playback);
      expect(guard.isBusy, isTrue);

      var secondTaken = false;
      final second = guard.acquire(ProviderUse.playback).then((lease) {
        secondTaken = true;
        return lease;
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(secondTaken, isFalse, reason: 'must not open a 2nd connection');

      first.release();
      final lease = await second;
      expect(secondTaken, isTrue);
      lease.release();
      guard.dispose();
    });

    test('playback pre-empts a running download', () async {
      final guard = ConnectionGuard();
      final download = guard.tryAcquire(ProviderUse.download)!;
      var preempted = false;
      download.onPreempted = () => preempted = true;

      final playback = await guard.acquire(ProviderUse.playback);
      expect(preempted, isTrue);
      expect(download.isReleased, isTrue);

      playback.release();
      guard.dispose();
    });

    test('a download cannot start while playback holds the connection', () {
      final guard = ConnectionGuard();
      final playback = guard.tryAcquire(ProviderUse.playback)!;
      expect(guard.tryAcquire(ProviderUse.download), isNull);
      playback.release();
      guard.dispose();
    });

    test('a multi-connection account may download while watching', () async {
      final guard = ConnectionGuard(maxConnections: 2);
      guard.configure(maxConnections: 2, allowConcurrentDownloads: true);
      final playback = guard.tryAcquire(ProviderUse.playback)!;
      final download = guard.tryAcquire(ProviderUse.download);
      expect(download, isNotNull);
      playback.release();
      download!.release();
      guard.dispose();
    });

    test('concurrent downloads stay off when the account allows only one',
        () async {
      final guard = ConnectionGuard();
      guard.configure(maxConnections: 1, allowConcurrentDownloads: true);
      // The toggle is meaningless on a one-connection account.
      expect(guard.allowConcurrentDownloads, isFalse);
      guard.dispose();
    });

    test('releasing twice is harmless', () async {
      final guard = ConnectionGuard();
      final lease = await guard.acquire(ProviderUse.probe);
      lease.release();
      lease.release();
      expect(guard.isBusy, isFalse);
      guard.dispose();
    });

    test('the handover gap is applied between consecutive leases', () async {
      final guard = ConnectionGuard();
      final first = await guard.acquire(ProviderUse.playback);
      first.release();

      final sw = Stopwatch()..start();
      final second = await guard.acquire(ProviderUse.playback);
      sw.stop();

      // The provider needs a beat to notice the old socket closed.
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(600));
      second.release();
      guard.dispose();
    });

    test('withConnection releases even when the body throws', () async {
      final guard = ConnectionGuard();
      await expectLater(
        guard.withConnection<void>(
          ProviderUse.probe,
          (_) async => throw StateError('boom'),
        ),
        throwsStateError,
      );
      expect(guard.isBusy, isFalse);
      guard.dispose();
    });
  });
}
