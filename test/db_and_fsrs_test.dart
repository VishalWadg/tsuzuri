import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';

void main() {
  group('Phase 3 & Phase 5: Dual Databases, Backup/Restore, and FSRS Scheduling', () {
    late UserDatabase userDb;
    late ContentDatabase contentDb;
    late FsrsSchedulerService scheduler;

    setUp(() {
      userDb = UserDatabase.openInMemory();
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      scheduler = FsrsSchedulerService();
    });

    tearDown(() {
      userDb.close();
      contentDb.close();
    });

    test('Content DB loads pre-sampled kanji keyed by Unicode codepoint (Fix #2 & #7)', () {
      expect(contentDb.totalKanjiCount, greaterThanOrEqualTo(20));
      final sun = contentDb.getKanjiByCodepoint(0x65E5); // 日
      expect(sun, isNotNull);
      expect(sun!.literal, equals('日'));
      expect(sun.strokeCount, equals(4));
      expect(sun.strokes.length, equals(4));
      expect(sun.strokes.first.sampledPoints.length, equals(50));
    });

    test('FSRS grade derivation maps mistakes and hints accurately (Phase 5)', () {
      expect(
        FsrsSchedulerService.deriveGrade(mistakes: 0, hintsUsed: 0),
        equals(PracticeGrade.easy),
      );
      expect(
        FsrsSchedulerService.deriveGrade(mistakes: 1, hintsUsed: 0),
        equals(PracticeGrade.good),
      );
      expect(
        FsrsSchedulerService.deriveGrade(mistakes: 2, hintsUsed: 0),
        equals(PracticeGrade.hard),
      );
      expect(
        FsrsSchedulerService.deriveGrade(mistakes: 0, hintsUsed: 1),
        equals(PracticeGrade.hard),
      );
      expect(
        FsrsSchedulerService.deriveGrade(mistakes: 3, hintsUsed: 0),
        equals(PracticeGrade.again),
      );
    });

    test('User DB stores progress keyed by (codepoint, mode) and exports/restores backup (Fix #1, #9, #11)', () {
      final now = DateTime.utc(2026, 11, 3, 6, 0);
      final updated = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x4E00, // 一
        mistakes: 0,
        hintsUsed: 0,
        mode: PracticeMode.writing,
        now: now,
      );

      expect(updated.codepoint, equals(0x4E00));
      expect(updated.reps, equals(1));
      expect(updated.dueDate.isAfter(now), isTrue);

      // Export JSON backup and restore into a brand-new UserDatabase instance (simulating reinstall)
      final backupJson = userDb.exportBackupJson();
      final restoredDb = UserDatabase.openInMemory();
      restoredDb.importBackupJson(backupJson);

      final restoredCard = restoredDb.getCard(0x4E00, mode: PracticeMode.writing);
      expect(restoredCard, isNotNull);
      expect(restoredCard!.reps, equals(1));
      expect(restoredCard.stability, closeTo(updated.stability, 1e-6));
      restoredDb.close();
    });

    test('Daily queue orders due cards first, then new cards up to daily limit (Phase 5)', () {
      final past = DateTime.utc(2026, 10, 1, 12, 0);
      // Schedule U+5C71 (山) in the past so it is due now
      userDb.upsertCard(
        UserCardProgress(
          codepoint: 0x5C71,
          mode: PracticeMode.writing,
          dueDate: past,
          stability: 2.5,
          difficulty: 5.0,
          elapsedDays: 0,
          scheduledDays: 1,
          reps: 1,
          lapses: 0,
          state: 2,
          lastReview: past,
        ),
      );

      final queue = scheduler.buildDailyQueue(
        contentDb: contentDb,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2026, 11, 3, 12, 0),
      );

      // 1 due card + 5 new cards = 6 items total, with the due card (山) first
      expect(queue.length, equals(6));
      expect(queue.first.kanji.codepoint, equals(0x5C71));
      expect(queue.first.isNew, isFalse);
      expect(queue[1].isNew, isTrue);
    });
  });
}
