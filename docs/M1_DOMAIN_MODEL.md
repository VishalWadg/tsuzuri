# Tsuzuri — Milestone 1: Domain Model Specification

**Document Reference**: `docs/M1_DOMAIN_MODEL.md`  
**Application**: Tsuzuri (綴り) — Offline-first Japanese Kanji Learning Application  
**Milestone**: Milestone 1 (Exercise Abstraction — Phase 1: Design & Analysis)  
**Status**: Proposal / Domain Model Contract (Updated post Final Contract Clarifications)  
**Date**: November 2026  
**Author**: Antigravity Senior Flutter Architecture Team  

---

## 1. Domain Concept Overview & Implementation Status

| Domain Concept | M1 Status | Target File | Pure-Dart Dependency Boundary & Rules |
|---|---|---|---|
| **`ExerciseActivity`** | **Implemented** | `lib/src/domain/exercises/exercise_types.dart` | Pure Dart enum: `writing`, `recognition`. |
| **`ExerciseType`** | **Implemented** | `lib/src/domain/exercises/exercise_types.dart` | Pure Dart enum: all 8 planned variations, only `meaningToKanji` active in M1. |
| **`SkillType`** | **Implemented** | `lib/src/domain/exercises/exercise_types.dart` | Pure Dart enum: `writingRecall`, `meaningRecognition`, `readingRecognition`, `listeningRecognition`, `writingDiagnostic`. Explicit SQLite mapping via `dbKey`. |
| **`AnswerType`** | **Implemented** | `lib/src/domain/exercises/exercise_types.dart` | Pure Dart enum: `handwriting`, `multipleChoice`, `spoken`, `flashcardSelfReport`. |
| **`ExercisePrompt`** | **Implemented** | `lib/src/domain/exercises/exercise_prompt.dart` | **`sealed class`** (Pure Dart, `package:meta/meta.dart`). Base for all prompt types. Enforces Unicode scalar range. |
| **`MeaningPrompt`** | **Implemented** | `lib/src/domain/exercises/exercise_prompt.dart` | **`final class`** extending `ExercisePrompt`. Unmodifiable collections (`meanings`, `onyomi`, `kunyomi`). Complete string and stroke count validation. |
| **`ExerciseAnswerMethod`** | **Implemented** | `lib/src/domain/exercises/exercise_answer_method.dart` | **`sealed class`** (Pure Dart, `package:meta/meta.dart`). Base for all input methods. |
| **`HandwritingAnswerMethod`** | **Implemented** | `lib/src/domain/exercises/exercise_answer_method.dart` | **`final class`** extending `ExerciseAnswerMethod`. Wraps `List<ReferenceStroke>` in `List.unmodifiable()`. `ReferenceStroke` verified deeply immutable. |
| **`ExerciseDefinition`** | **Implemented** | `lib/src/domain/exercises/exercise_definition.dart` | Pure Dart immutable aggregate. **Strictly enforces M1 combination**: `meaningToKanji` + `writingRecall` + `MeaningPrompt` + `HandwritingAnswerMethod`. |
| **`ExerciseResult`** | **Implemented** | `lib/src/domain/exercises/exercise_result.dart` | Pure Dart outcome carrier: mistakes, hints, duration, Unicode codepoint. **Computed getter `isFirstAttemptClean`**. Zero FSRS logic. |

---

## 2. Core Enumerations (`exercise_types.dart`)

```dart
// Pure Dart — no Flutter dependencies

/// The broad activity category of practice.
enum ExerciseActivity {
  writing,
  recognition;

  String get displayName {
    switch (this) {
      case ExerciseActivity.writing:
        return 'Writing Practice';
      case ExerciseActivity.recognition:
        return 'Recognition Practice';
    }
  }
}

/// The specific cognitive skill tracked by the learning system.
enum SkillType {
  writingRecall,
  meaningRecognition,
  readingRecognition,
  listeningRecognition,
  writingDiagnostic;

  /// String key stored in SQLite database (srs_cards / review_logs).
  ///
  /// In M1, only [writingRecall] maps to Schema v2 ('writing').
  /// Unsupported skill mappings fail explicitly with [UnsupportedError].
  String get dbKey {
    switch (this) {
      case SkillType.writingRecall:
        return 'writing';
      case SkillType.meaningRecognition:
      case SkillType.readingRecognition:
      case SkillType.listeningRecognition:
      case SkillType.writingDiagnostic:
        throw UnsupportedError(
          'SkillType.$name is not supported in SQLite schema v2. '
          'Card persistence for recognition and diagnostic skills requires Schema v3.',
        );
    }
  }
}

/// The specific exercise variation.
enum ExerciseType {
  // Writing Variations
  meaningToKanji,      // Active in M1
  audioToKanji,        // Planned future milestone
  referenceCopy,       // Planned future milestone
  guidedStrokeWriting, // Planned future milestone

  // Recognition Variations
  kanjiToMeaning,      // Planned future milestone
  kanjiToReading,      // Planned future milestone
  audioToMeaning,      // Planned future milestone
  meaningToReading;    // Planned future milestone

  ExerciseActivity get activity {
    switch (this) {
      case ExerciseType.meaningToKanji:
      case ExerciseType.audioToKanji:
      case ExerciseType.referenceCopy:
      case ExerciseType.guidedStrokeWriting:
        return ExerciseActivity.writing;
      case ExerciseType.kanjiToMeaning:
      case ExerciseType.kanjiToReading:
      case ExerciseType.audioToMeaning:
      case ExerciseType.meaningToReading:
        return ExerciseActivity.recognition;
    }
  }

  SkillType get primarySkill {
    switch (this) {
      case ExerciseType.meaningToKanji:
      case ExerciseType.audioToKanji:
      case ExerciseType.guidedStrokeWriting:
        return SkillType.writingRecall;
      case ExerciseType.referenceCopy:
        return SkillType.writingDiagnostic;
      case ExerciseType.kanjiToMeaning:
      case ExerciseType.audioToMeaning:
        return SkillType.meaningRecognition;
      case ExerciseType.kanjiToReading:
      case ExerciseType.meaningToReading:
        return SkillType.readingRecognition;
    }
  }
}

/// The user input modality required by the exercise.
enum AnswerType {
  handwriting,
  multipleChoice,
  spoken,
  flashcardSelfReport;
}
```

---

## 3. Exercise Prompt Model (`exercise_prompt.dart`)

```dart
// Pure Dart — only package:meta/meta.dart is imported
import 'package:meta/meta.dart';

/// Helper for pure-Dart list equality without Flutter foundation dependency.
bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Validates that [codepoint] is a valid Unicode scalar value.
///
/// Must be positive, <= 0x10FFFF, and outside the surrogate range (0xD800–0xDFFF).
bool isValidUnicodeScalar(int codepoint) {
  return codepoint > 0 &&
      codepoint <= 0x10FFFF &&
      (codepoint < 0xD800 || codepoint > 0xDFFF);
}

/// Sealed base class for all exercise prompts.
@immutable
sealed class ExercisePrompt {
  final int codepoint;
  final String literal;

  const ExercisePrompt({
    required this.codepoint,
    required this.literal,
  });
}

/// Concrete sealed variant representing a Meaning-based writing prompt.
@immutable
final class MeaningPrompt extends ExercisePrompt {
  final List<String> meanings;
  final List<String> onyomi;
  final List<String> kunyomi;
  final int strokeCount;

  MeaningPrompt({
    required super.codepoint,
    required super.literal,
    required List<String> meanings,
    required List<String> onyomi,
    required List<String> kunyomi,
    required this.strokeCount,
  })  : meanings = List.unmodifiable(meanings),
        onyomi = List.unmodifiable(onyomi),
        kunyomi = List.unmodifiable(kunyomi) {
    if (!isValidUnicodeScalar(codepoint)) {
      throw ArgumentError.value(
        codepoint,
        'codepoint',
        'Must be a valid Unicode scalar value (1..0x10FFFF, excluding 0xD800..0xDFFF)',
      );
    }
    if (literal.trim().isEmpty) {
      throw ArgumentError.value(literal, 'literal', 'Kanji character literal cannot be empty');
    }
    if (this.meanings.isEmpty) {
      throw ArgumentError.value(meanings, 'meanings', 'At least one meaning must be provided');
    }
    if (this.meanings.any((m) => m.trim().isEmpty)) {
      throw ArgumentError.value(meanings, 'meanings', 'Meanings cannot contain empty strings');
    }
    if (strokeCount <= 0) {
      throw ArgumentError.value(strokeCount, 'strokeCount', 'Stroke count must be positive');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeaningPrompt &&
          runtimeType == other.runtimeType &&
          codepoint == other.codepoint &&
          literal == other.literal &&
          _listEquals(meanings, other.meanings) &&
          _listEquals(onyomi, other.onyomi) &&
          _listEquals(kunyomi, other.kunyomi) &&
          strokeCount == other.strokeCount;

  @override
  int get hashCode => Object.hash(
        codepoint,
        literal,
        Object.hashAll(meanings),
        Object.hashAll(onyomi),
        Object.hashAll(kunyomi),
        strokeCount,
      );
}
```

---

## 4. Exercise Answer Method Model (`exercise_answer_method.dart`)

```dart
// Pure Dart — only package:meta/meta.dart and local matcher models are imported
import 'package:meta/meta.dart';
import '../../matching/stroke_matcher.dart';
import 'exercise_types.dart';

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Sealed base class for exercise answer methods.
@immutable
sealed class ExerciseAnswerMethod {
  final AnswerType answerType;

  const ExerciseAnswerMethod({required this.answerType});
}

/// Concrete sealed variant configuring canvas-based handwriting input.
///
/// Wraps [referenceStrokes] in [List.unmodifiable]. Elements of type [ReferenceStroke]
/// are verified to have only `final` fields and immutable [Point2D] coordinates.
@immutable
final class HandwritingAnswerMethod extends ExerciseAnswerMethod {
  final List<ReferenceStroke> referenceStrokes;
  final double leniency;
  final bool hintsEnabled;
  final bool hapticsEnabled;

  HandwritingAnswerMethod({
    required List<ReferenceStroke> referenceStrokes,
    this.leniency = 1.0,
    this.hintsEnabled = true,
    this.hapticsEnabled = true,
  })  : referenceStrokes = List.unmodifiable(referenceStrokes),
        super(answerType: AnswerType.handwriting) {
    if (this.referenceStrokes.isEmpty) {
      throw ArgumentError.value(
        referenceStrokes,
        'referenceStrokes',
        'Reference strokes cannot be empty for handwriting practice',
      );
    }
    if (leniency <= 0) {
      throw ArgumentError.value(leniency, 'leniency', 'Leniency must be positive');
    }
  }

  int get totalStrokes => referenceStrokes.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandwritingAnswerMethod &&
          runtimeType == other.runtimeType &&
          leniency == other.leniency &&
          hintsEnabled == other.hintsEnabled &&
          hapticsEnabled == other.hapticsEnabled &&
          _listEquals(referenceStrokes, other.referenceStrokes);

  @override
  int get hashCode => Object.hash(
        leniency,
        hintsEnabled,
        hapticsEnabled,
        Object.hashAll(referenceStrokes),
      );
}
```

---

## 5. Exercise Definition & Result Models

### 5.1 `ExerciseDefinition` (`exercise_definition.dart`)
```dart
// Pure Dart
import 'package:meta/meta.dart';
import '../../data/models.dart';
import 'exercise_answer_method.dart';
import 'exercise_prompt.dart';
import 'exercise_types.dart';

/// Immutable definition of an exercise ready for presentation and evaluation.
///
/// In Milestone 1, explicitly validates that the single supported combination is used:
/// meaningToKanji + writingRecall + MeaningPrompt + HandwritingAnswerMethod.
@immutable
class ExerciseDefinition {
  final String id;
  final ExerciseType exerciseType;
  final SkillType skillType;
  final KanjiCharacter character;
  final ExercisePrompt prompt;
  final ExerciseAnswerMethod answerMethod;

  ExerciseDefinition({
    required this.id,
    required this.exerciseType,
    required this.skillType,
    required this.character,
    required this.prompt,
    required this.answerMethod,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Exercise id cannot be empty');
    }
    if (!isValidUnicodeScalar(character.codepoint)) {
      throw ArgumentError.value(
        character.codepoint,
        'character.codepoint',
        'Invalid Unicode scalar value',
      );
    }
    if (character.codepoint != prompt.codepoint) {
      throw ArgumentError(
        'Character codepoint (${character.codepoint}) must match prompt codepoint (${prompt.codepoint})',
      );
    }
    if (character.literal != prompt.literal) {
      throw ArgumentError(
        'Character literal (${character.literal}) must match prompt literal (${prompt.literal})',
      );
    }

    // Strict Milestone 1 combination enforcement
    if (exerciseType != ExerciseType.meaningToKanji ||
        exerciseType.activity != ExerciseActivity.writing ||
        skillType != SkillType.writingRecall ||
        prompt is! MeaningPrompt ||
        answerMethod is! HandwritingAnswerMethod) {
      throw ArgumentError(
        'Milestone 1 only supports ExerciseType.meaningToKanji with '
        'SkillType.writingRecall, MeaningPrompt, and HandwritingAnswerMethod',
      );
    }
  }

  ExerciseActivity get activity => exerciseType.activity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExerciseDefinition &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          exerciseType == other.exerciseType &&
          skillType == other.skillType &&
          character.codepoint == other.character.codepoint;

  @override
  int get hashCode => Object.hash(id, exerciseType, skillType, character.codepoint);
}
```

### 5.2 `ExerciseResult` (`exercise_result.dart`)
```dart
// Pure Dart
import 'package:meta/meta.dart';
import 'exercise_prompt.dart';
import 'exercise_types.dart';

/// Pure outcome data carrier recording the metrics of an exercise attempt.
///
/// DOES NOT own FSRS scheduling, grade derivation, or persistence logic.
@immutable
class ExerciseResult {
  final String exerciseId;
  final ExerciseType exerciseType;
  final int codepoint;
  final String literal;
  final bool isCompleted;
  final int mistakes;
  final int hintsUsed;
  final Duration elapsed;

  ExerciseResult({
    required this.exerciseId,
    required this.exerciseType,
    required this.codepoint,
    required this.literal,
    required this.isCompleted,
    required this.mistakes,
    required this.hintsUsed,
    required this.elapsed,
  }) {
    if (exerciseId.trim().isEmpty) {
      throw ArgumentError.value(exerciseId, 'exerciseId', 'Exercise id cannot be empty');
    }
    if (!isValidUnicodeScalar(codepoint)) {
      throw ArgumentError.value(codepoint, 'codepoint', 'Invalid Unicode scalar value');
    }
    if (literal.trim().isEmpty) {
      throw ArgumentError.value(literal, 'literal', 'Literal cannot be empty');
    }
    if (mistakes < 0) {
      throw ArgumentError.value(mistakes, 'mistakes', 'Mistakes cannot be negative');
    }
    if (hintsUsed < 0) {
      throw ArgumentError.value(hintsUsed, 'hintsUsed', 'Hints used cannot be negative');
    }
    if (elapsed < Duration.zero) {
      throw ArgumentError.value(elapsed, 'elapsed', 'Elapsed duration cannot be negative');
    }
  }

  /// Computed getter guaranteeing internal state consistency with mistakes and hints.
  bool get isFirstAttemptClean => mistakes == 0 && hintsUsed == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExerciseResult &&
          runtimeType == other.runtimeType &&
          exerciseId == other.exerciseId &&
          exerciseType == other.exerciseType &&
          codepoint == other.codepoint &&
          literal == other.literal &&
          isCompleted == other.isCompleted &&
          mistakes == other.mistakes &&
          hintsUsed == other.hintsUsed &&
          elapsed == other.elapsed;

  @override
  int get hashCode => Object.hash(
        exerciseId,
        exerciseType,
        codepoint,
        literal,
        isCompleted,
        mistakes,
        hintsUsed,
        elapsed,
      );
}
```

---

## 6. Evaluation Decoupling & FSRS Integration

### 6.1 Separation of Outcomes from Scheduling
`ExerciseResult` carries the outcome of what the user drew on the canvas. It does not contain `PracticeGrade`, nor does it invoke FSRS formulas.

When the canvas triggers `onCompleted(mistakes, hintsUsed)`:
1. `_PracticeScreenState` packages the attempt metrics into an `ExerciseResult`.
2. The screen-level handler calls the existing `FsrsSchedulerService`:
   ```dart
   final grade = FsrsSchedulerService.deriveGrade(
     mistakes: result.mistakes,
     hintsUsed: result.hintsUsed,
   );
   final updatedCard = scheduler.recordPracticeCompletion(
     userDb: userDb,
     codepoint: result.codepoint,
     mistakes: result.mistakes,
     hintsUsed: result.hintsUsed,
   );
   ```

### 6.2 Strict Skill Mapping and Persistence Boundary
- In Milestone 1, `exercise.skillType` is `SkillType.writingRecall`.
- `SkillType.writingRecall.dbKey` maps to `'writing'`.
- If an unsupported skill type is ever passed to `dbKey`, an `UnsupportedError` is thrown immediately.
- SQLite tables `srs_cards` and `review_logs` remain unchanged.
