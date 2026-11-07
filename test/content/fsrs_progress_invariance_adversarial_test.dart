import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/registry/content_repository.dart';
import 'package:offline_kanji_practice/src/content/registry/content_source_registry.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

// ============================================================================
// Test Doubles & Helpers
// ============================================================================

class FakeSpeechService implements ISpeechService {
  @override
  Future<bool> isJapaneseVoiceAvailable() async => true;
  @override
  Future<void> speakJapanese(String text, {double rate = 1.0}) async {}
  @override
  Future<void> stop() async {}
}

class MockCustomMetadataSource implements IKanjiMetadataSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, KanjiMetadataEntry> entries;
  bool shouldThrow;
  Object throwError;

  MockCustomMetadataSource({
    required this.sourceId,
    this.displayName = 'Mock Custom Metadata',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, KanjiMetadataEntry>? entries,
    this.shouldThrow = false,
    this.throwError = const FormatException('Simulated metadata read failure'),
  }) : entries = entries != null ? Map.from(entries) : {};

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async {
    if (shouldThrow) throw throwError;
    return entries[codepoint];
  }

  KanjiMetadataEntry? getMetadataSync(int codepoint) {
    if (shouldThrow) throw throwError;
    return entries[codepoint];
  }

  @override
  Future<List<int>> getAllCodepoints() async {
    if (shouldThrow) throw throwError;
    return entries.keys.toList();
  }

  List<int> getAllCodepointsSync() {
    if (shouldThrow) throw throwError;
    return entries.keys.toList();
  }

  @override
  Future<int> getCharacterCount() async => entries.length;

  @override
  Future<List<String>> generateMeaningDistractors(KanjiMetadataEntry target, {int count = 3}) async =>
      const ['distractor_m1', 'distractor_m2', 'distractor_m3'];

  @override
  Future<List<String>> generateReadingDistractors(KanjiMetadataEntry target, {int count = 3}) async =>
      const ['dist_r1', 'dist_r2', 'dist_r3'];
}

class MockCustomStrokeSource implements IKanjiStrokeSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, List<ReferenceStroke>> strokesMap;
  bool shouldThrow;
  Object throwError;

  MockCustomStrokeSource({
    required this.sourceId,
    this.displayName = 'Mock Custom Strokes',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, List<ReferenceStroke>>? strokesMap,
    this.shouldThrow = false,
    this.throwError = const FileSystemException('Simulated stroke read failure'),
  }) : strokesMap = strokesMap != null ? Map.from(strokesMap) : {};

  @override
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) async {
    if (shouldThrow) throw throwError;
    return strokesMap[codepoint];
  }

  List<ReferenceStroke>? getStrokesSync(int codepoint) {
    if (shouldThrow) throw throwError;
    return strokesMap[codepoint];
  }

  @override
  Future<bool> containsStrokes(int codepoint) async {
    if (shouldThrow) throw throwError;
    return strokesMap.containsKey(codepoint);
  }
}

UserCardProgress copyWithDue(UserCardProgress p, DateTime due) {
  return UserCardProgress(
    codepoint: p.codepoint,
    mode: p.mode,
    dueDate: due,
    stability: p.stability,
    difficulty: p.difficulty,
    elapsedDays: p.elapsedDays,
    scheduledDays: p.scheduledDays,
    reps: p.reps,
    lapses: p.lapses,
    state: p.state,
    lastReview: p.lastReview,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentDatabase bundledContentDb;
  late FsrsSchedulerService scheduler;
  late Directory tempDir;

  setUpAll(() {
    final assetFile = File('assets/db/kanji_content.db');
    if (!assetFile.existsSync()) {
      throw StateError('Bundled assets/db/kanji_content.db not found');
    }
    bundledContentDb = ContentDatabase.openFromFile(assetFile);
    scheduler = FsrsSchedulerService();
  });

  tearDownAll(() {
    bundledContentDb.close();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tsuzuri_adversarial_fsrs_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('Adversarial FSRS Progress Invariance (Requirement R3)', () {
    test('Empirical Verification: Database Row Invariance & Safe Queue Omission across Source Lifecycle', () async {
      // 1. Setup real on-disk SQLite UserDatabase
      final userDb = await UserDatabase.openFromDirectory(tempDir);
      final rawDb = sql.sqlite3.open(userDb.filePath!);

      // 2. Setup Registry & Facade with bundled defaults
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb), priority: 0);
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb), priority: 0);
      registry.registerAudioSource(
        DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb),
        priority: 0,
      );
      final repository = ContentRepository(registry: registry);

      // 3. Define 5 custom Kanji (codepoints 0x9FF0 to 0x9FF4)
      final customCodepoints = [0x9FF0, 0x9FF1, 0x9FF2, 0x9FF3, 0x9FF4];
      final customMetaMap = <int, KanjiMetadataEntry>{};
      final customStrokesMap = <int, List<ReferenceStroke>>{};

      for (var i = 0; i < customCodepoints.length; i++) {
        final cp = customCodepoints[i];
        customMetaMap[cp] = KanjiMetadataEntry(
          codepoint: cp,
          literal: String.fromCharCode(cp),
          strokeCount: 10 + i,
          grade: 9,
          jlptLevel: 1,
          frequency: 9000 + i,
          meanings: ['CustomMeaning_$i'],
          onyomi: ['カスタム_$i'],
          kunyomi: ['かすたむ_$i'],
        );
        customStrokesMap[cp] = [
          const ReferenceStroke(
            strokeOrder: 1,
            strokeType: 'horizontal',
            svgPath: 'M 10 10 L 90 90',
            arcLength: 100.0,
            sampledPoints: [Point2D(0.1, 0.1), Point2D(0.9, 0.9)],
          ),
        ];
      }

      // 4. Also pick 5 bundled Kanji (0x4E00 '一', 0x4E8C '二', 0x4E09 '三', 0x56DB '四', 0x4E94 '五')
      final bundledCodepoints = [0x4E00, 0x4E8C, 0x4E09, 0x56DB, 0x4E94];

      // 5. Seed user_progress.db with heterogeneous cards and review logs for both sets
      final baseDate = DateTime.utc(2026, 10, 1, 10, 0);

      // Seed Bundled cards with varying FSRS states
      for (var i = 0; i < bundledCodepoints.length; i++) {
        final cp = bundledCodepoints[i];
        final card = UserCardProgress(
          codepoint: cp,
          mode: PracticeMode.writing,
          dueDate: baseDate.add(Duration(days: i)),
          stability: 2.0 + (i * 1.5),
          difficulty: 4.0 + (i * 0.5),
          elapsedDays: i + 1,
          scheduledDays: i + 2,
          reps: i + 1,
          lapses: i % 2,
          state: (i % 3) + 1, // 1 (learning), 2 (review), 3 (relearning)
          lastReview: baseDate.subtract(Duration(days: i)),
        );
        userDb.upsertCard(card);

        // Add 2 review logs for each bundled card
        userDb.insertReviewLog(
          codepoint: cp,
          mode: PracticeMode.writing,
          rating: 3,
          mistakes: 0,
          hintsUsed: 0,
          reviewedAt: baseDate.subtract(Duration(days: i + 1)),
        );
        userDb.insertReviewLog(
          codepoint: cp,
          mode: PracticeMode.writing,
          rating: 2,
          mistakes: 1,
          hintsUsed: 1,
          reviewedAt: baseDate.subtract(Duration(days: i)),
        );
      }

      // Seed Custom cards with distinct FSRS states
      for (var i = 0; i < customCodepoints.length; i++) {
        final cp = customCodepoints[i];
        final card = UserCardProgress(
          codepoint: cp,
          mode: PracticeMode.writing,
          dueDate: baseDate.add(Duration(days: i)), // Due between Oct 1 and Oct 5
          stability: 3.5 + (i * 2.0),
          difficulty: 5.5 - (i * 0.4),
          elapsedDays: 2 + i,
          scheduledDays: 4 + i,
          reps: 3 + i,
          lapses: i == 2 ? 1 : 0,
          state: 2, // review
          lastReview: baseDate.subtract(const Duration(days: 1)),
        );
        userDb.upsertCard(card);

        // Add review logs for each custom card
        userDb.insertReviewLog(
          codepoint: cp,
          mode: PracticeMode.writing,
          rating: 4,
          mistakes: 0,
          hintsUsed: 0,
          reviewedAt: baseDate.subtract(const Duration(days: 2)),
        );
        userDb.insertReviewLog(
          codepoint: cp,
          mode: PracticeMode.writing,
          rating: 3,
          mistakes: 0,
          hintsUsed: 0,
          reviewedAt: baseDate.subtract(const Duration(days: 1)),
        );

        // Add writing metrics
        userDb.insertWritingMetric(
          codepoint: cp,
          exerciseType: 'writing',
          shapeScore: 0.95 - (i * 0.05),
          orderErrors: 0,
          retries: 0,
          durationMs: 3200 + (i * 100),
          recordedAt: baseDate.subtract(const Duration(days: 1)),
        );
      }

      // Verify seeding count
      final initialCards = rawDb.select('SELECT COUNT(*) AS cnt FROM srs_cards;').first['cnt'] as int;
      final initialLogs = rawDb.select('SELECT COUNT(*) AS cnt FROM review_logs;').first['cnt'] as int;
      final initialMetrics = rawDb.select('SELECT COUNT(*) AS cnt FROM writing_metrics;').first['cnt'] as int;
      expect(initialCards, equals(10), reason: '5 bundled + 5 custom cards');
      expect(initialLogs, equals(20), reason: '2 logs per card * 10 cards');
      expect(initialMetrics, equals(5), reason: '5 custom writing metrics');

      // -----------------------------------------------------------------------
      // Step A: Register Custom Source & Verify Presence in Queue
      // -----------------------------------------------------------------------
      final customMetaSource = MockCustomMetadataSource(
        sourceId: 'custom_rare_pack',
        entries: customMetaMap,
      );
      final customStrokeSource = MockCustomStrokeSource(
        sourceId: 'custom_rare_pack_strokes',
        strokesMap: customStrokesMap,
      );
      registry.registerMetadataSource(customMetaSource, priority: 50);
      registry.registerStrokeSource(customStrokeSource, priority: 50);
      repository.clearCache();

      // Queue evaluation date: Oct 4, 2026.
      // Bundled cards 0, 1, 2, 3 (Oct 1, 2, 3, 4) and Custom cards 0, 1, 2, 3 (Oct 1, 2, 3, 4) are due!
      final evalDate = DateTime.utc(2026, 10, 4, 12, 0);

      final queueWithCustom = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0, // Due cards only
        now: evalDate,
      );

      final queueCodepointsWithCustom = queueWithCustom.map((q) => q.kanji.codepoint).toSet();
      // Should contain due custom cards (0x9FF0, 0x9FF1, 0x9FF2, 0x9FF3)
      expect(queueCodepointsWithCustom.contains(0x9FF0), isTrue);
      expect(queueCodepointsWithCustom.contains(0x9FF1), isTrue);
      expect(queueCodepointsWithCustom.contains(0x9FF2), isTrue);
      expect(queueCodepointsWithCustom.contains(0x9FF3), isTrue);
      // And due bundled cards (0x4E00, 0x4E8C, 0x4E09, 0x56DB)
      expect(queueCodepointsWithCustom.contains(0x4E00), isTrue);
      expect(queueCodepointsWithCustom.contains(0x4E8C), isTrue);
      expect(queueCodepointsWithCustom.contains(0x4E09), isTrue);
      expect(queueCodepointsWithCustom.contains(0x56DB), isTrue);

      // -----------------------------------------------------------------------
      // Step B: Snapshot Database State Before Source Unregistration
      // -----------------------------------------------------------------------
      final srsCardsSnapshot = rawDb.select('SELECT * FROM srs_cards ORDER BY codepoint, mode;');
      final reviewLogsSnapshot = rawDb.select('SELECT * FROM review_logs ORDER BY id;');
      final writingMetricsSnapshot = rawDb.select('SELECT * FROM writing_metrics ORDER BY id;');

      // Detailed field verification map for custom cards
      final customCardStateBefore = <int, Map<String, Object?>>{};
      for (final cp in customCodepoints) {
        final card = userDb.getCard(cp)!;
        customCardStateBefore[cp] = {
          'stability': card.stability,
          'difficulty': card.difficulty,
          'elapsedDays': card.elapsedDays,
          'scheduledDays': card.scheduledDays,
          'reps': card.reps,
          'lapses': card.lapses,
          'state': card.state,
          'dueDate': card.dueDate.toIso8601String(),
          'lastReview': card.lastReview?.toIso8601String(),
        };
      }

      // -----------------------------------------------------------------------
      // Step C: Unregister Custom Sources & Trigger Dangling Queue Builds
      // -----------------------------------------------------------------------
      registry.unregisterSource('custom_rare_pack');
      registry.unregisterSource('custom_rare_pack_strokes');
      repository.clearCache();

      // Verify custom source is truly unregistered
      expect(registry.containsSource('custom_rare_pack'), isFalse);
      expect(registry.containsSource('custom_rare_pack_strokes'), isFalse);

      // Build daily queue MULTIPLE times across simulated intervals:
      // Interval 1: evalDate (Oct 4)
      // Interval 2: Oct 10 (all 5 custom cards and all 5 bundled cards are due)
      // Interval 3: Oct 20 (future review date)
      final testDates = [
        evalDate,
        DateTime.utc(2026, 10, 10, 12, 0),
        DateTime.utc(2026, 10, 20, 12, 0),
      ];

      for (final testDate in testDates) {
        // Run synchronous buildDailyQueue
        final queue = scheduler.buildDailyQueue(
          repository: repository,
          userDb: userDb,
          dailyNewLimit: 5,
          now: testDate,
        );

        // a) Verify: Unregistered custom kanji are safely omitted without throwing
        for (final cp in customCodepoints) {
          expect(
            queue.any((q) => q.kanji.codepoint == cp),
            isFalse,
            reason: 'Custom kanji 0x${cp.toRadixString(16)} must be omitted when unregistered',
          );
        }

        // Bundled cards due on testDate must still be present!
        final bundledDueInQueue = queue.where((q) => bundledCodepoints.contains(q.kanji.codepoint)).toList();
        expect(bundledDueInQueue, isNotEmpty, reason: 'Bundled due cards must continue to appear');

        // Also run asynchronous buildDailyQueueAsync
        final asyncQueue = await scheduler.buildDailyQueueAsync(
          repository: repository,
          userDb: userDb,
          dailyNewLimit: 5,
          now: testDate,
        );

        for (final cp in customCodepoints) {
          expect(
            asyncQueue.any((q) => q.kanji.codepoint == cp),
            isFalse,
            reason: 'Async queue must also safely omit custom kanji 0x${cp.toRadixString(16)}',
          );
        }
      }

      // -----------------------------------------------------------------------
      // Step D: Verify Exact Invariance of Database Tables (Requirement R3)
      // -----------------------------------------------------------------------
      // b) Verify exact stability, difficulty, reps, lapses, timestamps in srs_cards
      for (final cp in customCodepoints) {
        final cardAfter = userDb.getCard(cp);
        expect(cardAfter, isNotNull, reason: 'Card for 0x${cp.toRadixString(16)} must NOT be deleted');

        final before = customCardStateBefore[cp]!;
        expect(cardAfter!.stability, equals(before['stability']), reason: 'Stability invariance');
        expect(cardAfter.difficulty, equals(before['difficulty']), reason: 'Difficulty invariance');
        expect(cardAfter.elapsedDays, equals(before['elapsedDays']), reason: 'ElapsedDays invariance');
        expect(cardAfter.scheduledDays, equals(before['scheduledDays']), reason: 'ScheduledDays invariance');
        expect(cardAfter.reps, equals(before['reps']), reason: 'Reps invariance');
        expect(cardAfter.lapses, equals(before['lapses']), reason: 'Lapses invariance');
        expect(cardAfter.state, equals(before['state']), reason: 'State invariance');
        expect(cardAfter.dueDate.toIso8601String(), equals(before['dueDate']), reason: 'DueDate invariance');
        expect(cardAfter.lastReview?.toIso8601String(), equals(before['lastReview']), reason: 'LastReview invariance');
      }

      // d) Verify Zero Database Mutations or Deletions across all tables
      final srsCardsAfter = rawDb.select('SELECT * FROM srs_cards ORDER BY codepoint, mode;');
      final reviewLogsAfter = rawDb.select('SELECT * FROM review_logs ORDER BY id;');
      final writingMetricsAfter = rawDb.select('SELECT * FROM writing_metrics ORDER BY id;');

      expect(srsCardsAfter.length, equals(srsCardsSnapshot.length), reason: 'Zero row additions/deletions in srs_cards');
      expect(reviewLogsAfter.length, equals(reviewLogsSnapshot.length), reason: 'Zero row additions/deletions in review_logs');
      expect(writingMetricsAfter.length, equals(writingMetricsSnapshot.length), reason: 'Zero mutations in writing_metrics');

      for (var i = 0; i < srsCardsSnapshot.length; i++) {
        final rowBefore = srsCardsSnapshot[i];
        final rowAfter = srsCardsAfter[i];
        for (final key in rowBefore.keys) {
          expect(rowAfter[key], equals(rowBefore[key]), reason: 'srs_cards row $i column $key changed!');
        }
      }

      for (var i = 0; i < reviewLogsSnapshot.length; i++) {
        final rowBefore = reviewLogsSnapshot[i];
        final rowAfter = reviewLogsAfter[i];
        for (final key in rowBefore.keys) {
          expect(rowAfter[key], equals(rowBefore[key]), reason: 'review_logs row $i column $key changed!');
        }
      }

      for (var i = 0; i < writingMetricsSnapshot.length; i++) {
        final rowBefore = writingMetricsSnapshot[i];
        final rowAfter = writingMetricsAfter[i];
        for (final key in rowBefore.keys) {
          expect(rowAfter[key], equals(rowBefore[key]), reason: 'writing_metrics row $i column $key changed!');
        }
      }

      // -----------------------------------------------------------------------
      // Step E: Re-register Custom Sources & Verify Immediate Restoration
      // -----------------------------------------------------------------------
      registry.registerMetadataSource(customMetaSource, priority: 75);
      registry.registerStrokeSource(customStrokeSource, priority: 75);
      repository.clearCache();

      // c) When custom source is re-registered, cards immediately reappear at scheduled interval
      final restoredQueue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: DateTime.utc(2026, 10, 10, 12, 0), // All cards are due
      );

      final restoredCodepoints = restoredQueue.map((q) => q.kanji.codepoint).toSet();
      for (final cp in customCodepoints) {
        expect(
          restoredCodepoints.contains(cp),
          isTrue,
          reason: 'Custom kanji 0x${cp.toRadixString(16)} must immediately reappear in queue when source re-registered',
        );

        final queueItem = restoredQueue.firstWhere((q) => q.kanji.codepoint == cp);
        expect(queueItem.isNew, isFalse, reason: 'Restored card must not be treated as new');
        expect(queueItem.existingProgress, isNotNull);

        final progress = queueItem.existingProgress!;
        final before = customCardStateBefore[cp]!;
        expect(progress.stability, equals(before['stability']));
        expect(progress.difficulty, equals(before['difficulty']));
        expect(progress.reps, equals(before['reps']));
        expect(progress.lapses, equals(before['lapses']));
      }

      // -----------------------------------------------------------------------
      // Step F: Execute Review on Restored Card & Verify Continuous FSRS Evolution
      // -----------------------------------------------------------------------
      final targetCp = customCodepoints[0];
      final targetBefore = userDb.getCard(targetCp)!;
      final practiceDate = DateTime.utc(2026, 10, 10, 14, 0);

      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: targetCp,
        mistakes: 0,
        hintsUsed: 0,
        now: practiceDate,
      );

      final targetAfter = userDb.getCard(targetCp)!;
      expect(targetAfter.reps, equals(targetBefore.reps + 1), reason: 'Reps must increment');
      expect(targetAfter.stability, greaterThan(targetBefore.stability), reason: 'Stability must increase after successful review');
      expect(targetAfter.lastReview?.toUtc().toIso8601String(), equals(practiceDate.toIso8601String()));

      // SQLite integrity check
      final integrityResult = rawDb.select('PRAGMA integrity_check;').first.values.first as String;
      expect(integrityResult, equals('ok'), reason: 'SQLite integrity must remain ok');

      rawDb.dispose();
      userDb.close();
    });

    test('Adversarial Churn: 10 Rapid Cycles of Register -> Review -> Unregister -> Queue Verification', () async {
      final userDb = await UserDatabase.openFromDirectory(tempDir);
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb), priority: 0);
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb), priority: 0);
      final repository = ContentRepository(registry: registry);

      const testCodepoint = 0x9FFE;
      final customMeta = MockCustomMetadataSource(
        sourceId: 'churn_pack',
        entries: {
          testCodepoint: const KanjiMetadataEntry(
            codepoint: testCodepoint,
            literal: '鿾',
            strokeCount: 14,
            grade: 1, // Grade 1 ensures high priority in new card ordering
            jlptLevel: 5,
            meanings: ['ChurnMeaning'],
            onyomi: ['チョーン'],
            kunyomi: ['ちょうん'],
          ),
        },
      );

      var simTime = DateTime.utc(2026, 11, 1, 9, 0);

      // Perform 10 churn cycles
      for (var cycle = 1; cycle <= 10; cycle++) {
        // 1. Register
        registry.registerMetadataSource(customMeta, priority: 10 + cycle);
        repository.clearCache();

        // 2. Queue with source active -> card should be present
        final qActive = scheduler.buildDailyQueue(
          repository: repository,
          userDb: userDb,
          dailyNewLimit: 5,
          now: simTime,
        );
        expect(qActive.any((q) => q.kanji.codepoint == testCodepoint), isTrue,
            reason: 'Cycle $cycle: Card must appear when registered');

        // 3. Record review
        scheduler.recordPracticeCompletion(
          userDb: userDb,
          codepoint: testCodepoint,
          mistakes: 0,
          hintsUsed: 0,
          now: simTime,
        );

        final cardState = userDb.getCard(testCodepoint)!;
        expect(cardState.reps, equals(cycle), reason: 'Cycle $cycle: Reps must match cycle count');

        // Snapshot DB card state
        final snapStability = cardState.stability;
        final snapReps = cardState.reps;
        final snapDue = cardState.dueDate;

        // 4. Advance time past due date
        simTime = cardState.dueDate.add(const Duration(hours: 1));

        // 5. Unregister
        registry.unregisterSource('churn_pack');
        repository.clearCache();

        // 6. Queue with source absent -> card safely omitted
        final qAbsent = scheduler.buildDailyQueue(
          repository: repository,
          userDb: userDb,
          dailyNewLimit: 5,
          now: simTime,
        );
        expect(qAbsent.any((q) => q.kanji.codepoint == testCodepoint), isFalse,
            reason: 'Cycle $cycle: Card must be omitted when unregistered');

        // 7. Verify DB invariance while unregistered
        final cardAfterOmission = userDb.getCard(testCodepoint)!;
        expect(cardAfterOmission.stability, equals(snapStability));
        expect(cardAfterOmission.reps, equals(snapReps));
        expect(cardAfterOmission.dueDate, equals(snapDue));
      }

      userDb.close();
    });

    test('Adversarial Fault Containment: Faulty/Crashing Custom Source Preserves Queue and User DB', () async {
      final userDb = await UserDatabase.openFromDirectory(tempDir);
      final rawDb = sql.sqlite3.open(userDb.filePath!);

      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb), priority: 0);
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb), priority: 0);
      final repository = ContentRepository(registry: registry);

      const faultyCp = 0x9FFB;
      const bundledCp = 0x4E00;

      // Seed both cards due in past
      final pastDate = DateTime.utc(2026, 10, 1, 10, 0);
      userDb.upsertCard(UserCardProgress(
        codepoint: faultyCp,
        mode: PracticeMode.writing,
        dueDate: pastDate,
        stability: 5.0,
        difficulty: 4.0,
        elapsedDays: 5,
        scheduledDays: 5,
        reps: 4,
        lapses: 0,
        state: 2,
        lastReview: pastDate.subtract(const Duration(days: 5)),
      ));
      userDb.upsertCard(UserCardProgress(
        codepoint: bundledCp,
        mode: PracticeMode.writing,
        dueDate: pastDate,
        stability: 10.0,
        difficulty: 2.0,
        elapsedDays: 10,
        scheduledDays: 10,
        reps: 8,
        lapses: 0,
        state: 2,
        lastReview: pastDate.subtract(const Duration(days: 10)),
      ));

      // Register crashing custom metadata source without backdoor entries
      final crashingSource = MockCustomMetadataSource(
        sourceId: 'crashing_source',
        entries: {}, // No readable entries map
        shouldThrow: true,
        throwError: const FileSystemException('I/O fault during disk read of custom pack'),
      );
      registry.registerMetadataSource(crashingSource, priority: 100);
      repository.clearCache();

      final srsSnapshot = rawDb.select('SELECT * FROM srs_cards ORDER BY codepoint;');

      // Execute buildDailyQueue
      final queue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2026, 11, 1, 12, 0),
      );

      // Faulty card omitted safely, bundled card present
      expect(queue.any((q) => q.kanji.codepoint == faultyCp), isFalse);
      expect(queue.any((q) => q.kanji.codepoint == bundledCp), isTrue);

      // Verify zero DB mutations
      final srsAfter = rawDb.select('SELECT * FROM srs_cards ORDER BY codepoint;');
      expect(srsAfter.length, equals(srsSnapshot.length));
      for (var i = 0; i < srsSnapshot.length; i++) {
        for (final col in srsSnapshot[i].keys) {
          expect(srsAfter[i][col], equals(srsSnapshot[i][col]));
        }
      }

      rawDb.dispose();
      userDb.close();
    });

    test('Partial Unregistration: Custom Metadata Unregistered but Custom Strokes Remain', () async {
      final userDb = UserDatabase.openInMemory();
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb), priority: 0);
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb), priority: 0);
      final repository = ContentRepository(registry: registry);

      const customCp = 0x9FFA;
      final pastDate = DateTime.utc(2026, 10, 1, 10, 0);

      userDb.upsertCard(UserCardProgress(
        codepoint: customCp,
        mode: PracticeMode.writing,
        dueDate: pastDate,
        stability: 2.0,
        difficulty: 5.0,
        elapsedDays: 1,
        scheduledDays: 1,
        reps: 1,
        lapses: 0,
        state: 1,
        lastReview: pastDate,
      ));

      // Register both metadata and strokes
      final metaSource = MockCustomMetadataSource(
        sourceId: 'meta_pack',
        entries: {
          customCp: const KanjiMetadataEntry(
            codepoint: customCp,
            literal: '鿺',
            strokeCount: 11,
            meanings: ['Partial'],
          ),
        },
      );
      final strokeSource = MockCustomStrokeSource(
        sourceId: 'stroke_pack',
        strokesMap: {
          customCp: [
            const ReferenceStroke(
              strokeOrder: 1,
              strokeType: 'horizontal',
              svgPath: 'M 20 20 L 80 80',
              arcLength: 85.0,
              sampledPoints: [Point2D(0.2, 0.2), Point2D(0.8, 0.8)],
            ),
          ],
        },
      );

      registry.registerMetadataSource(metaSource, priority: 50);
      registry.registerStrokeSource(strokeSource, priority: 50);
      repository.clearCache();

      // Verify present
      final q1 = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: DateTime.utc(2026, 11, 1),
      );
      expect(q1.any((q) => q.kanji.codepoint == customCp), isTrue);

      // Unregister ONLY metadata source
      registry.unregisterSource('meta_pack');
      repository.clearCache();

      // Verify safely omitted because metadata is unresolvable
      final q2 = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: DateTime.utc(2026, 11, 1),
      );
      expect(q2.any((q) => q.kanji.codepoint == customCp), isFalse);

      // Card in userDb is intact
      final card = userDb.getCard(customCp);
      expect(card, isNotNull);
      expect(card!.codepoint, equals(customCp));

      userDb.close();
    });

    test('Empirical Investigation: Repository Cache Eviction on Source Unregistration', () {
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb), priority: 0);
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb), priority: 0);
      final repository = ContentRepository(registry: registry);

      const customCp = 0x9FF8;
      final metaSource = MockCustomMetadataSource(
        sourceId: 'cache_test_pkg',
        entries: {
          customCp: const KanjiMetadataEntry(
            codepoint: customCp,
            literal: '鿸',
            strokeCount: 15,
            meanings: ['CacheTest'],
          ),
        },
      );

      registry.registerMetadataSource(metaSource, priority: 10);
      // Query to warm repository cache
      final kanjiBefore = repository.getKanjiByCodepointSync(customCp);
      expect(kanjiBefore, isNotNull);

      // Unregister source
      registry.unregisterSource('cache_test_pkg');

      // Check whether repository cache auto-invalidates on unregisterSource
      final kanjiWithoutClearCache = repository.getKanjiByCodepointSync(customCp);
      // Auto-invalidation ensures kanjiWithoutClearCache is null without explicit clearCache()
      expect(kanjiWithoutClearCache, isNull,
          reason: 'Repository._resolvedCache auto-invalidates when source is unregistered');

      // With clearCache()
      repository.clearCache();
      final kanjiAfterClearCache = repository.getKanjiByCodepointSync(customCp);
      expect(kanjiAfterClearCache, isNull, reason: 'After clearCache(), unregistered kanji returns null');
    });

    test('Empirical Boundary: Pure async custom source (no sync duck-typing) requires buildDailyQueueAsync', () async {
      final userDb = UserDatabase.openInMemory();
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb), priority: 0);
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb), priority: 0);
      final repository = ContentRepository(registry: registry);

      const pureAsyncCp = 0x9FF7;
      final pastDate = DateTime.utc(2026, 10, 1, 10, 0);

      userDb.upsertCard(UserCardProgress(
        codepoint: pureAsyncCp,
        mode: PracticeMode.writing,
        dueDate: pastDate,
        stability: 3.0,
        difficulty: 4.0,
        elapsedDays: 2,
        scheduledDays: 2,
        reps: 2,
        lapses: 0,
        state: 2,
        lastReview: pastDate,
      ));

      // Pure async source with private map and no duck-typed synchronous getters
      final pureAsyncSource = PureAsyncMetadataSource({
        pureAsyncCp: const KanjiMetadataEntry(
          codepoint: pureAsyncCp,
          literal: '鿷',
          strokeCount: 16,
          meanings: ['PureAsync'],
        ),
      });

      registry.registerMetadataSource(pureAsyncSource, priority: 50);
      repository.clearCache();

      // 1. Synchronous buildDailyQueue cannot resolve pure async custom source without preloaded cache
      final syncQueue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: DateTime.utc(2026, 11, 1),
      );
      expect(syncQueue.any((q) => q.kanji.codepoint == pureAsyncCp), isFalse,
          reason: 'Synchronous queue safely omits pure async source whose data is not cached');

      // 2. Asynchronous buildDailyQueueAsync resolves it properly through the interface contract
      final asyncQueue = await scheduler.buildDailyQueueAsync(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: DateTime.utc(2026, 11, 1),
      );
      expect(asyncQueue.any((q) => q.kanji.codepoint == pureAsyncCp), isTrue,
          reason: 'Asynchronous queue successfully resolves pure async IKanjiMetadataSource');

      // 3. Once resolved by async call, it warms the cache, making sync resolution work afterwards
      final syncQueueAfterWarm = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: DateTime.utc(2026, 11, 1),
      );
      expect(syncQueueAfterWarm.any((q) => q.kanji.codepoint == pureAsyncCp), isTrue,
          reason: 'Warmed repository cache allows synchronous queue to resolve cached character');

      userDb.close();
    });
  });
}

class PureAsyncMetadataSource implements IKanjiMetadataSource {
  @override final String sourceId = 'pure_async_pkg';
  @override final String displayName = 'Pure Async Metadata';
  @override final String version = '1.0.0';
  @override final bool isBundledDefault = false;

  final Map<int, KanjiMetadataEntry> _privateMap;
  PureAsyncMetadataSource(this._privateMap);

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async => _privateMap[codepoint];

  @override
  Future<List<int>> getAllCodepoints() async => _privateMap.keys.toList();

  @override
  Future<int> getCharacterCount() async => _privateMap.length;

  @override
  Future<List<String>> generateMeaningDistractors(KanjiMetadataEntry target, {int count = 3}) async => const [];

  @override
  Future<List<String>> generateReadingDistractors(KanjiMetadataEntry target, {int count = 3}) async => const [];
}

