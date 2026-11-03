import 'package:fsrs/fsrs.dart' as fsrs_pkg;
import '../data/content_db.dart';
import '../data/models.dart';
import '../data/user_db.dart';

/// FSRS Grade derived automatically from mistakes and hints used during a kanji write (Section 4 & Phase 5).
enum PracticeGrade {
  again(1, 'Again'),
  hard(2, 'Hard'),
  good(3, 'Good'),
  easy(4, 'Easy');

  final int value;
  final String label;
  const PracticeGrade(this.value, this.label);
}

/// Review queue item pairing a [KanjiCharacter] with its existing [UserCardProgress] (if studied).
class PracticeQueueItem {
  final KanjiCharacter kanji;
  final UserCardProgress? existingProgress;

  const PracticeQueueItem({
    required this.kanji,
    this.existingProgress,
  });

  bool get isNew => existingProgress == null;
}

/// FSRS Scheduler Service (Fix #9 & Phase 5).
///
/// - Uses the official `fsrs` Dart package parameters instead of hand-rolled formulas.
/// - Treats each `(codepoint, mode)` pair as a separate card.
/// - Automatically maps `(mistakes, hintsUsed)` on character completion to `Again`, `Hard`, `Good`, or `Easy`.
/// - Builds the daily review queue: due cards first, then new cards up to the daily limit.
class FsrsSchedulerService {
  final fsrs_pkg.Scheduler _fsrs;

  FsrsSchedulerService({fsrs_pkg.Scheduler? fsrsInstance})
      : _fsrs = fsrsInstance ?? fsrs_pkg.Scheduler();

  /// Maps stroke mistakes and hints used to a [PracticeGrade] without requiring self-rating (Section 4).
  static PracticeGrade deriveGrade({
    required int mistakes,
    required int hintsUsed,
  }) {
    if (mistakes >= 3 || hintsUsed >= 2) {
      return PracticeGrade.again;
    }
    if (mistakes == 2 || hintsUsed == 1) {
      return PracticeGrade.hard;
    }
    if (mistakes == 1 && hintsUsed == 0) {
      return PracticeGrade.good;
    }
    return PracticeGrade.easy;
  }

  /// Schedules a completed kanji practice attempt and persists the updated card + review log.
  UserCardProgress recordPracticeCompletion({
    required UserDatabase userDb,
    required int codepoint,
    required int mistakes,
    required int hintsUsed,
    String mode = PracticeMode.writing,
    DateTime? now,
  }) {
    final reviewTime = (now ?? DateTime.now()).toUtc();
    final grade = deriveGrade(mistakes: mistakes, hintsUsed: hintsUsed);
    final existing = userDb.getCard(codepoint, mode: mode);

    final fsrsCard = existing != null ? _toFsrsCard(existing) : fsrs_pkg.Card(cardId: codepoint);
    final rating = _toFsrsRating(grade);

    final result = _fsrs.reviewCard(fsrsCard, rating, reviewDateTime: reviewTime);
    final updatedFsrsCard = result.card;

    final updatedProgress = UserCardProgress(
      codepoint: codepoint,
      mode: mode,
      dueDate: updatedFsrsCard.due.toUtc(),
      stability: updatedFsrsCard.stability ?? 0.0,
      difficulty: updatedFsrsCard.difficulty ?? 0.0,
      elapsedDays: existing != null && existing.lastReview != null
          ? reviewTime.difference(existing.lastReview!).inDays
          : 0,
      scheduledDays: updatedFsrsCard.due.difference(reviewTime).inDays,
      reps: (existing?.reps ?? 0) + 1,
      lapses: (existing?.lapses ?? 0) + (grade == PracticeGrade.again ? 1 : 0),
      state: updatedFsrsCard.state == fsrs_pkg.State.review
          ? 2
          : (updatedFsrsCard.state == fsrs_pkg.State.relearning ? 3 : 1),
      lastReview: reviewTime,
    );

    userDb.upsertCard(updatedProgress);
    userDb.insertReviewLog(
      codepoint: codepoint,
      mode: mode,
      rating: grade.value,
      mistakes: mistakes,
      hintsUsed: hintsUsed,
      reviewedAt: reviewTime,
    );

    return updatedProgress;
  }

  /// Builds the daily queue: due cards first (ordered by `due_date ASC`),
  /// followed by unstudied kanji ordered by school grade / JLPT level up to [dailyNewLimit].
  List<PracticeQueueItem> buildDailyQueue({
    required ContentDatabase contentDb,
    required UserDatabase userDb,
    required int dailyNewLimit,
    String mode = PracticeMode.writing,
    DateTime? now,
  }) {
    final currentTime = (now ?? DateTime.now()).toUtc();
    final queue = <PracticeQueueItem>[];

    // 1. Due cards first
    final dueCards = userDb.getDueCards(now: currentTime, mode: mode);
    for (final card in dueCards) {
      final kanji = contentDb.getKanjiByCodepoint(card.codepoint);
      if (kanji != null) {
        queue.add(PracticeQueueItem(kanji: kanji, existingProgress: card));
      }
    }

    // 2. New cards up to remaining daily allowance
    final studiedSet = userDb.getStudiedCodepoints(mode: mode);
    final orderedCodepoints = contentDb.getOrderedCodepoints();
    var addedNew = 0;

    for (final cp in orderedCodepoints) {
      if (addedNew >= dailyNewLimit) break;
      if (studiedSet.contains(cp)) continue;
      final kanji = contentDb.getKanjiByCodepoint(cp);
      if (kanji != null) {
        queue.add(PracticeQueueItem(kanji: kanji, existingProgress: null));
        addedNew++;
      }
    }

    return queue;
  }

  static fsrs_pkg.Card _toFsrsCard(UserCardProgress progress) {
    fsrs_pkg.State state;
    switch (progress.state) {
      case 2:
        state = fsrs_pkg.State.review;
        break;
      case 3:
        state = fsrs_pkg.State.relearning;
        break;
      default:
        state = fsrs_pkg.State.learning;
        break;
    }
    return fsrs_pkg.Card(
      cardId: progress.codepoint,
      due: progress.dueDate.toUtc(),
      stability: progress.stability > 0 ? progress.stability : null,
      difficulty: progress.difficulty > 0 ? progress.difficulty : null,
      state: state,
      lastReview: progress.lastReview?.toUtc(),
    );
  }

  static fsrs_pkg.Rating _toFsrsRating(PracticeGrade grade) {
    switch (grade) {
      case PracticeGrade.again:
        return fsrs_pkg.Rating.again;
      case PracticeGrade.hard:
        return fsrs_pkg.Rating.hard;
      case PracticeGrade.good:
        return fsrs_pkg.Rating.good;
      case PracticeGrade.easy:
        return fsrs_pkg.Rating.easy;
    }
  }
}
