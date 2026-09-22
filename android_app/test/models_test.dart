import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:theottdeals/data/models/account.dart';
import 'package:theottdeals/data/models/content.dart';
import 'package:theottdeals/data/models/epg.dart';
import 'package:theottdeals/data/models/json.dart';
import 'package:theottdeals/data/models/library.dart';

void main() {
  group('defensive json readers', () {
    test('ids survive being strings, ints or empty', () {
      expect(asInt('42'), 42);
      expect(asInt(42), 42);
      expect(asInt(''), 0);
      expect(asInt(null), 0);
      expect(asIntOrNull(''), isNull);
      expect(asInt('not a number', 7), 7);
    });

    test('bools accept the shapes panels actually send', () {
      expect(asBool(1), isTrue);
      expect(asBool('1'), isTrue);
      expect(asBool('true'), isTrue);
      expect(asBool(0), isFalse);
      expect(asBool(''), isFalse);
      expect(asBool(null), isFalse);
    });

    test('asMapList handles an object keyed by index', () {
      final out = asMapList({'0': {'a': 1}, '1': {'a': 2}});
      expect(out, hasLength(2));
      expect(out.first['a'], 1);
    });

    test('decodeEpgText decodes base64 but leaves plain text alone', () {
      final encoded = base64.encode(utf8.encode('Evening News'));
      expect(decodeEpgText(encoded), 'Evening News');
      expect(decodeEpgText('Evening News'), 'Evening News');
      expect(decodeEpgText(''), '');
    });
  });

  group('auth validation mirrors the PC app', () {
    test("auth == '0' as a string counts as unauthenticated", () {
      final info = XtreamUserInfo.fromJson({'auth': '0', 'username': 'u'});
      expect(info.isAuthenticated, isFalse);
    });

    test('auth == 0 as an int counts as unauthenticated', () {
      final info = XtreamUserInfo.fromJson({'auth': 0});
      expect(info.isAuthenticated, isFalse);
    });

    test('a missing status is treated as Active, like the PC app', () {
      final info = XtreamUserInfo.fromJson({'auth': 1});
      expect(info.isAuthenticated, isTrue);
      expect(info.isActive, isTrue);
    });

    test('a non-Active status is rejected', () {
      final info = XtreamUserInfo.fromJson({'auth': 1, 'status': 'Expired'});
      expect(info.isActive, isFalse);
    });

    test('max_connections is never below 1', () {
      expect(XtreamUserInfo.fromJson({'max_connections': 0}).maxConnections, 1);
      expect(XtreamUserInfo.fromJson({'max_connections': '3'}).maxConnections, 3);
    });
  });

  group('url normalisation', () {
    test('trailing slashes are stripped', () {
      expect(Account.normaliseUrl('http://x.com:8080///'), 'http://x.com:8080');
    });

    test('a bare host gets an http scheme', () {
      expect(Account.normaliseUrl('x.com:8080'), 'http://x.com:8080');
    });

    test('https is left alone', () {
      expect(Account.normaliseUrl('https://x.com'), 'https://x.com');
    });
  });

  group('content models', () {
    test('container_extension is honoured, mp4 is only a fallback', () {
      final mkv = Movie.fromJson({
        'stream_id': 1,
        'name': 'A',
        'container_extension': 'mkv',
      });
      expect(mkv.ext, 'mkv');
      final none = Movie.fromJson({'stream_id': 2, 'name': 'B'});
      expect(none.ext, 'mp4');
    });

    test('series episodes parse from a season-keyed object', () {
      final detail = SeriesDetail.fromJson(
        const Series(seriesId: 9, name: 'S', categoryId: '1'),
        {
          'info': {'plot': 'p'},
          'episodes': {
            '1': [
              {'id': '11', 'episode_num': 2, 'title': 'Two'},
              {'id': '10', 'episode_num': 1, 'title': 'One'},
            ],
            '2': [
              {'id': '20', 'episode_num': 1, 'title': 'S2E1'},
            ],
          },
        },
      );
      expect(detail.seasonNumbers, [1, 2]);
      expect(detail.episodeCount, 3);
      // Episodes are sorted by number regardless of response order.
      expect(detail.seasons[1]!.first.title, 'One');
    });

    test('nextAfter crosses the season boundary and stops at the end', () {
      final detail = SeriesDetail.fromJson(
        const Series(seriesId: 9, name: 'S', categoryId: '1'),
        {
          'episodes': {
            '1': [
              {'id': '10', 'episode_num': 1},
              {'id': '11', 'episode_num': 2},
            ],
            '2': [
              {'id': '20', 'episode_num': 1},
            ],
          },
        },
      );
      final s1e1 = detail.seasons[1]![0];
      final s1e2 = detail.seasons[1]![1];
      final s2e1 = detail.seasons[2]![0];

      expect(detail.nextAfter(s1e1)?.id, '11');
      expect(detail.nextAfter(s1e2)?.id, '20');
      expect(detail.nextAfter(s2e1), isNull);
    });

    test('episode tag is zero padded for filenames', () {
      final detail = SeriesDetail.fromJson(
        const Series(seriesId: 1, name: 'S', categoryId: ''),
        {
          'episodes': {
            '1': [
              {'id': '1', 'episode_num': 2},
            ],
          },
        },
      );
      expect(detail.seasons[1]!.first.tag, 'S01E02');
    });
  });

  group('EPG', () {
    test('progress is computed locally and clamped', () {
      final now = DateTime(2024, 1, 1, 12, 30);
      final p = EpgProgramme(
        id: '1',
        channelId: 'c',
        title: 't',
        start: DateTime(2024, 1, 1, 12),
        end: DateTime(2024, 1, 1, 13),
      );
      expect(p.progressAt(now), closeTo(0.5, 0.001));
      expect(p.progressAt(DateTime(2024, 1, 1, 11)), 0);
      expect(p.progressAt(DateTime(2024, 1, 1, 14)), 1);
      expect(p.isLiveAt(now), isTrue);
    });

    test('now/next are picked out of an unordered list', () {
      final at = DateTime(2024, 1, 1, 12, 30);
      final programmes = [
        EpgProgramme(
          id: 'next',
          channelId: 'c',
          title: 'Next',
          start: DateTime(2024, 1, 1, 13),
          end: DateTime(2024, 1, 1, 14),
        ),
        EpgProgramme(
          id: 'now',
          channelId: 'c',
          title: 'Now',
          start: DateTime(2024, 1, 1, 12),
          end: DateTime(2024, 1, 1, 13),
        ),
      ];
      final guide = ChannelGuide.from('live:1', programmes, at);
      expect(guide.now?.id, 'now');
      expect(guide.next?.id, 'next');
    });

    test('an end before the start is repaired rather than trusted', () {
      final p = EpgProgramme.fromJson({
        'start_timestamp': 1700000000,
        'stop_timestamp': 1600000000,
        'title': base64.encode(utf8.encode('Bad')),
      });
      expect(p.end.isAfter(p.start), isTrue);
    });
  });

  group('history', () {
    HistoryEntry entry({
      required int resumeSec,
      required int durationSec,
      bool isLive = false,
    }) =>
        HistoryEntry(
          key: 'k',
          title: 't',
          isLive: isLive,
          resumeAt: Duration(seconds: resumeSec),
          duration: Duration(seconds: durationSec),
          updatedAt: DateTime.now(),
        );

    test('the Continue Watching predicate matches the PC app exactly', () {
      // Under 5s in: too early to bother resuming.
      expect(entry(resumeSec: 4, durationSec: 100).isContinueWatching, isFalse);
      // Comfortably mid-way: yes.
      expect(entry(resumeSec: 50, durationSec: 100).isContinueWatching, isTrue);
      // Past 95%: counts as finished.
      expect(entry(resumeSec: 96, durationSec: 100).isContinueWatching, isFalse);
      // No duration known: cannot be resumed.
      expect(entry(resumeSec: 50, durationSec: 0).isContinueWatching, isFalse);
      // Live never resumes.
      expect(
        entry(resumeSec: 50, durationSec: 100, isLive: true).isContinueWatching,
        isFalse,
      );
    });

    test('live rows persist zero position and duration', () {
      final json = entry(resumeSec: 50, durationSec: 100, isLive: true).toJson();
      expect(json['resumeAt'], 0);
      expect(json['duration'], 0);
    });

    test('a round trip through json preserves the entry', () {
      final original = entry(resumeSec: 30, durationSec: 120);
      final restored = HistoryEntry.fromJson(original.toJson());
      expect(restored.resumeAt, const Duration(seconds: 30));
      expect(restored.duration, const Duration(seconds: 120));
      expect(restored.isContinueWatching, isTrue);
    });
  });

  group('downloads', () {
    test('an interrupted download is requeued, not left downloading', () {
      final item = DownloadItem(
        id: '1',
        url: 'http://x/y.mp4',
        title: 'T',
        filePath: '/tmp/t.mp4',
        status: DownloadStatus.downloading,
        addedAt: DateTime.now(),
      );
      expect(item.toJson()['status'], 'queued');
    });

    test('waiting also returns to the queue on restart', () {
      final item = DownloadItem(
        id: '1',
        url: 'u',
        title: 'T',
        filePath: '/tmp/t.mp4',
        status: DownloadStatus.waiting,
        addedAt: DateTime.now(),
      );
      expect(item.toJson()['status'], 'queued');
    });

    test('a completed download keeps its status', () {
      final item = DownloadItem(
        id: '1',
        url: 'u',
        title: 'T',
        filePath: '/tmp/t.mp4',
        status: DownloadStatus.completed,
        addedAt: DateTime.now(),
      );
      expect(item.toJson()['status'], 'completed');
    });

    test('progress falls back sanely without a known total', () {
      final item = DownloadItem(
        id: '1',
        url: 'u',
        title: 'T',
        filePath: '/t',
        status: DownloadStatus.downloading,
        receivedBytes: 500,
        addedAt: DateTime.now(),
      );
      expect(item.progress, 0);
      expect(item.copyWith(totalBytes: 1000).progress, 0.5);
    });
  });
}
