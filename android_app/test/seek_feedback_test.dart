import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theottdeals/presentation/player/seek_feedback.dart';

/// Spec §21: pressing +10 repeatedly must accumulate into ONE overlay and
/// one logical seek target, never stack widgets or spawn controllers.
void main() {
  group('SeekFeedbackController', () {
    test('starts empty', () {
      final c = SeekFeedbackController();
      expect(c.accumulated, Duration.zero);
      c.dispose();
    });

    test('rapid presses in the same direction accumulate', () {
      final c = SeekFeedbackController();
      c.register(const Duration(seconds: 10));
      c.register(const Duration(seconds: 10));
      c.register(const Duration(seconds: 10));
      expect(c.accumulated, const Duration(seconds: 30));
      expect(c.isForward, isTrue);
      c.dispose();
    });

    test('reversing direction restarts the total rather than cancelling out',
        () {
      final c = SeekFeedbackController();
      c.register(const Duration(seconds: 10));
      c.register(const Duration(seconds: 10));
      c.register(const Duration(seconds: -10));
      // The user sees "-10", not "+10".
      expect(c.accumulated, const Duration(seconds: -10));
      expect(c.isForward, isFalse);
      c.dispose();
    });

    test('every press bumps the revision so the animation restarts', () {
      final c = SeekFeedbackController();
      final first = c.revision;
      c.register(const Duration(seconds: 10));
      final second = c.revision;
      c.register(const Duration(seconds: 10));
      expect(second, greaterThan(first));
      expect(c.revision, greaterThan(second));
      c.dispose();
    });

    test('the total resets once the window lapses', () {
      fakeAsync((async) {
        final c = SeekFeedbackController();
        c.register(const Duration(seconds: 10));
        expect(c.accumulated, const Duration(seconds: 10));

        async.elapse(SeekFeedbackController.window * 2);
        expect(c.accumulated, Duration.zero);

        // A fresh press after the reset starts from scratch.
        c.register(const Duration(seconds: 10));
        expect(c.accumulated, const Duration(seconds: 10));
        c.dispose();
        async.flushTimers();
      });
    });

    test('a press inside the window extends it rather than resetting early',
        () {
      fakeAsync((async) {
        final c = SeekFeedbackController();
        c.register(const Duration(seconds: 10));
        async.elapse(SeekFeedbackController.window ~/ 2);
        c.register(const Duration(seconds: 10));
        async.elapse(SeekFeedbackController.window ~/ 2 +
            const Duration(milliseconds: 50));
        // Still visible: the second press pushed the deadline out.
        expect(c.accumulated, const Duration(seconds: 20));
        c.dispose();
        async.flushTimers();
      });
    });

    test('listeners are notified on press', () {
      final c = SeekFeedbackController();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.register(const Duration(seconds: 10));
      expect(notifications, 1);
      c.register(const Duration(seconds: 10));
      expect(notifications, 2);
      c.dispose();
    });

    test('disposing cancels the pending reset timer', () {
      fakeAsync((async) {
        final c = SeekFeedbackController();
        c.register(const Duration(seconds: 10));
        c.dispose();
        // No pending timers means nothing fires against a dead notifier.
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
