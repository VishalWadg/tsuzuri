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
  final fsrs_pkg.FSRS _fsrs;

  FsrsSchedulerService({fsrs_pkg.FSRS? fsrsInstance})
      : _fsrs = fsrsInstance ?? fsrs_pkg.FSRS();

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

    final fsrsCard = existing != null ? _toFsrsCard(existing) : fsrs_pkg.Card();
    final rating = _toFsrsRating(grade);

    final schedulingCards = _fsrs.repeat(fsrsCard, reviewTime);
    final updatedFsrsCard = schedulingCards[rating]!.card;

    final updatedProgress = UserCardProgress(
      codepoint: codepoint,
      mode: mode,
      dueDate: updatedFsrsCard.due.toUtc(),
      stability: updatedFsrsCard.stability,
      difficulty: updatedFsrsCard.difficulty,
      elapsedDays: updatedFsrsCard.elapsedDays,
      scheduledDays: updatedFsrsCard.scheduledDays,
      reps: updatedFsrsCard.reps,
      lapses: updatedFsrsCard.lapses,
      state: updatedFsrsCard.state.index,
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
    final card = fsrs_pkg.Card()
      ..due = progress.dueDate.toUtc()
      ..stability = progress.stability
      ..difficulty = progress.difficulty
      ..elapsedDays = progress.elapsedDays
      ..scheduledDays = progress.scheduledDays
      ..reps = progress.reps
      ..lapses = progress.lapses
      ..state = fsrs_pkg.State.values[progress.state.clamp(0, fsrs_pkg.State.values.length - 1)];
    if (progress.lastReview != null) {
      card.lastReview = progress.lastReview!.toUtc();
    }
    return card;
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
