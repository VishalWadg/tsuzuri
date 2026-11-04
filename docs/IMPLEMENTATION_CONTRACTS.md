# Tsuzuri — Technical Implementation Contracts

**Document Reference**: `IMPLEMENTATION_CONTRACTS.md`  
**Application**: Tsuzuri (綴り)  
**Target Specification**: Practice & Learning System Functional Specification v1.0  
**Date**: November 2026  
**Auditor**: Antigravity Technical Architecture Team  

---

## 1. Domain Models & Entities

These contracts establish the core entities required by the configuration-driven exercise architecture. All entities are immutable.

### 1.1 Activity, Exercise & Skill Enums

```dart
/// The primary learning activity.
enum ExerciseActivity {
  writing('Writing Practice'),
  recognition('Recognition Practice');

  final String label;
  const ExerciseActivity(this.label);
}

/// The specific exercise variation being presented.
enum ExerciseType {
  // Writing Variations
  meaningToWrite(
    activity: ExerciseActivity.writing,
    skillType: SkillType.writingRecall,
    label: 'Meaning → Write Kanji',
    isFreeRecall: true,
  ),
  audioToWrite(
    activity: ExerciseActivity.writing,
    skillType: SkillType.writingRecall,
    label: 'Audio → Write Kanji',
    isFreeRecall: true,
  ),
  copyKanji(
    activity: ExerciseActivity.writing,
    skillType: SkillType.writingDiagnostic,
    label: 'Kanji Reference → Copy Kanji',
    isFreeRecall: false,
  ),
  guidedStrokeOrder(
    activity: ExerciseActivity.writing,
    skillType: SkillType.writingDiagnostic,
    label: 'Guided Stroke-Order Practice',
    isFreeRecall: false,
  ),

  // Recognition Variations
  kanjiToMeaning(
    activity: ExerciseActivity.recognition,
    skillType: SkillType.meaningRecognition,
    label: 'Kanji → Meaning',
    isFreeRecall: true,
  ),
  kanjiToReading(
    activity: ExerciseActivity.recognition,
    skillType: SkillType.readingRecognition,
    label: 'Kanji → Reading',
    isFreeRecall: true,
  ),
  meaningToKanji(
    activity: ExerciseActivity.recognition,
    skillType: SkillType.meaningRecognition,
    label: 'Meaning → Kanji',
    isFreeRecall: true,
  ),
  audioToRecognition(
    activity: ExerciseActivity.recognition,
    skillType: SkillType.listeningRecognition,
    label: 'Audio → Recognition',
    isFreeRecall: true,
  );

  final ExerciseActivity activity;
  final SkillType skillType;
  final String label;
  final bool isFreeRecall;

  const ExerciseType({
    required this.activity,
    required this.skillType,
    required this.label,
    required this.isFreeRecall,
  });
}

/// The independent cognitive skill receiving FSRS scheduling updates.
enum SkillType {
  writingRecall('writing_recall'),
  meaningRecognition('meaning_recognition'),
  readingRecognition('reading_recognition'),
  listeningRecognition('listening_recognition'),
  writingDiagnostic('writing_diagnostic'); // Diagnostic only; does not update FSRS card

  final String key;
  const SkillType(this.key);

  static SkillType fromKey(String key) {
    return SkillType.values.firstWhere(
      (e) => e.key == key,
      orElse: () => SkillType.writingRecall,
    );
  }
}
```

---

### 1.2 Prompt & Answer Representation

```dart
/// Discriminative union representing what the user sees or hears.
sealed class ExercisePrompt {
  const ExercisePrompt();
}

class MeaningPrompt extends ExercisePrompt {
  final List<String> meanings;
  final List<String>? onyomi;
  final List<String>? kunyomi;

  const MeaningPrompt({
    required this.meanings,
    this.onyomi,
    this.kunyomi,
  });
}

class AudioPrompt extends ExercisePrompt {
  final String audioText; // Kana pronunciation or word
  final String? contextualMeaning;
  final String? exampleWord;

  const AudioPrompt({
    required this.audioText,
    this.contextualMeaning,
    this.exampleWord,
  });
}

class ReferenceKanjiPrompt extends ExercisePrompt {
  final String literal;
  final List<ReferenceStroke> referenceStrokes;
  final List<String> meanings;

  const ReferenceKanjiPrompt({
    required this.literal,
    required this.referenceStrokes,
    required this.meanings,
  });
}

class GuidedWritingPrompt extends ExercisePrompt {
  final String literal;
  final int totalStrokes;
  final int currentStrokeNumber;
  final ReferenceStroke currentExpectedStroke;

  const GuidedWritingPrompt({
    required this.literal,
    required this.totalStrokes,
    required this.currentStrokeNumber,
    required this.currentExpectedStroke,
  });
}

/// Specification of how the user supplies the answer.
sealed class ExerciseAnswerMethod {
  const ExerciseAnswerMethod();
}

class HandwritingAnswerMethod extends ExerciseAnswerMethod {
  final List<ReferenceStroke> expectedStrokes;
  final LeniencyPreset leniency;
  final bool hintsEnabled;
  final bool copyMode;
  final bool guidedMode;

  const HandwritingAnswerMethod({
    required this.expectedStrokes,
    required this.leniency,
    required this.hintsEnabled,
    this.copyMode = false,
    this.guidedMode = false,
  });
}

class MultipleChoiceAnswerMethod extends ExerciseAnswerMethod {
  final List<String> options;
  final int correctOptionIndex;
  final String explanation;

  const MultipleChoiceAnswerMethod({
    required this.options,
    required this.correctOptionIndex,
    required this.explanation,
  });
}

/// Unified domain entity representing a complete generated exercise.
class ExerciseDefinition {
  final String exerciseId;
  final int targetCodepoint;
  final ExerciseType exerciseType;
  final ExercisePrompt prompt;
  final ExerciseAnswerMethod answerMethod;

  const ExerciseDefinition({
    required this.exerciseId,
    required this.targetCodepoint,
    required this.exerciseType,
    required this.prompt,
    required this.answerMethod,
  });
}
```

---

### 1.3 Configuration & Presets

```dart
/// Immutable configuration governing how exercises are presented.
class ExerciseConfiguration {
  final ExerciseActivity activity;
  final Set<ExerciseType> selectedTypes;
  final bool audioAutoplay;
  final bool audioReplay;
  final bool slowAudioSpeed;
  final bool showReferenceKanji;
  final bool showMeanings;
  final bool showReadings;
  final LeniencyPreset leniency;
  final bool hintsEnabled;
  final int questionsPerSession;

  const ExerciseConfiguration({
    required this.activity,
    required this.selectedTypes,
    this.audioAutoplay = true,
    this.audioReplay = true,
    this.slowAudioSpeed = false,
    this.showReferenceKanji = false,
    this.showMeanings = true,
    this.showReadings = true,
    this.leniency = LeniencyPreset.normal,
    this.hintsEnabled = true,
    this.questionsPerSession = 10,
  });

  /// Validates and resolves conditional settings conflicts (Section 5.5).
  ExerciseConfiguration sanitize() {
    var validTypes = selectedTypes.where((t) => t.activity == activity).toSet();
    if (validTypes.isEmpty) {
      validTypes = {
        activity == ExerciseActivity.writing
            ? ExerciseType.meaningToWrite
            : ExerciseType.kanjiToMeaning,
      };
    }

    final hasCopy = validTypes.contains(ExerciseType.copyKanji);
    final hasAudio = validTypes.any((t) => t == ExerciseType.audioToWrite || t == ExerciseType.audioToRecognition);

    return ExerciseConfiguration(
      activity: activity,
      selectedTypes: validTypes,
      audioAutoplay: hasAudio ? audioAutoplay : false,
      audioReplay: hasAudio ? audioReplay : false,
      slowAudioSpeed: hasAudio ? slowAudioSpeed : false,
      showReferenceKanji: hasCopy ? true : showReferenceKanji,
      showMeanings: showMeanings,
      showReadings: showReadings,
      leniency: leniency,
      hintsEnabled: hintsEnabled,
      questionsPerSession: questionsPerSession.clamp(1, 100),
    );
  }
}

/// Named predefined practice preset.
class PracticePreset {
  final String id;
  final String name;
  final String description;
  final ExerciseConfiguration configuration;
  final bool isDefault;

  const PracticePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.configuration,
    this.isDefault = false,
  });

  static const beginner = PracticePreset(
    id: 'preset_beginner',
    name: 'Beginner',
    description: 'Forgiving handwriting matching with visual hints and reference assistance.',
    configuration: ExerciseConfiguration(
      activity: ExerciseActivity.writing,
      selectedTypes: {ExerciseType.meaningToWrite},
      leniency: LeniencyPreset.forgiving,
      hintsEnabled: true,
      showReferenceKanji: false,
    ),
  );

  static const standard = PracticePreset(
    id: 'preset_standard',
    name: 'Standard',
    description: 'Normal stroke matching, standard audio playback, minimal hints.',
    configuration: ExerciseConfiguration(
      activity: ExerciseActivity.writing,
      selectedTypes: {ExerciseType.meaningToWrite},
      leniency: LeniencyPreset.normal,
      hintsEnabled: true,
      showReferenceKanji: false,
    ),
    isDefault: true,
  );

  static const challenge = PracticePreset(
    id: 'preset_challenge',
    name: 'Challenge',
    description: 'Strict stroke evaluation, zero hints, hidden readings.',
    configuration: ExerciseConfiguration(
      activity: ExerciseActivity.writing,
      selectedTypes: {ExerciseType.meaningToWrite},
      leniency: LeniencyPreset.strict,
      hintsEnabled: false,
      showReadings: false,
      showReferenceKanji: false,
    ),
  );
}
```

---

## 2. Service & Engine Interfaces

### 2.1 Exercise Engine

```dart
abstract interface class IExerciseEngine {
  /// Generates a concrete [ExerciseDefinition] for a given kanji and configuration.
  ExerciseDefinition generateExercise({
    required KanjiCharacter kanji,
    required ExerciseConfiguration configuration,
    required ExerciseType exerciseType,
  });

  /// Composes a practice session queue of exercises.
  List<ExerciseDefinition> generateSession({
    required List<KanjiCharacter> kanjiPool,
    required ExerciseConfiguration configuration,
  });
}
```

### 2.2 Speech Service

```dart
abstract interface class ISpeechService {
  /// Checks whether Japanese language speech synthesis is supported and installed offline.
  Future<bool> isJapaneseVoiceAvailable();

  /// Speaks the provided Japanese text ([text] can be kanji, kana, or vocabulary).
  Future<void> speak({
    required String text,
    bool slowSpeed = false,
  });

  /// Immediately stops any ongoing speech playback.
  Future<void> stop();

  /// Releases audio resources when the active exercise or screen disposes.
  void dispose();
}
```

### 2.3 Answer & Stroke Evaluators

```dart
/// Contract for evaluating multiple-choice answers in recognition mode.
abstract interface class IRecognitionEvaluator {
  bool evaluate({
    required int selectedIndex,
    required int expectedIndex,
  });
}

/// The existing [StrokeMatcher] already fulfills the stroke evaluation contract:
/// StrokeMatchResult StrokeMatcher.validateStroke(...)
```

---

## 3. Database Schema Evolution (Schema v3)

The existing `user_progress.db` schema will be upgraded from version 2 to version 3 using a non-destructive migration.

### 3.1 Migration SQL Script

```sql
-- Migration from Schema v2 to Schema v3
BEGIN TRANSACTION;

-- 1. Create temporary table with skill_type column
CREATE TABLE srs_cards_v3 (
  codepoint INTEGER NOT NULL,
  skill_type TEXT NOT NULL,
  due_date TEXT NOT NULL,
  stability REAL NOT NULL,
  difficulty REAL NOT NULL,
  elapsed_days INTEGER NOT NULL,
  scheduled_days INTEGER NOT NULL,
  reps INTEGER NOT NULL,
  lapses INTEGER NOT NULL,
  state INTEGER NOT NULL,
  last_review TEXT,
  PRIMARY KEY (codepoint, skill_type)
);

-- 2. Migrate existing records: map existing 'writing' mode to 'writing_recall' skill_type
INSERT INTO srs_cards_v3
SELECT 
  codepoint,
  CASE WHEN mode = 'writing' THEN 'writing_recall' ELSE mode END AS skill_type,
  due_date,
  stability,
  difficulty,
  elapsed_days,
  scheduled_days,
  reps,
  lapses,
  state,
  last_review
FROM srs_cards;

-- 3. Replace srs_cards table
DROP TABLE srs_cards;
ALTER TABLE srs_cards_v3 RENAME TO srs_cards;

CREATE INDEX idx_srs_cards_skill_due ON srs_cards(skill_type, due_date);

-- 4. Create diagnostic writing metrics table for copy & guided practice
CREATE TABLE writing_metrics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  attempt_id TEXT NOT NULL,
  codepoint INTEGER NOT NULL,
  exercise_type TEXT NOT NULL,
  shape_score REAL NOT NULL,
  order_errors INTEGER NOT NULL,
  retries INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  recorded_at TEXT NOT NULL
);

CREATE INDEX idx_writing_metrics_codepoint ON writing_metrics(codepoint);

-- 5. Create custom presets table
CREATE TABLE custom_presets (
  preset_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  configuration_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- 6. Update schema version
PRAGMA user_version = 3;

COMMIT;
```

---

## 4. Error Handling & Safety Invariants

The implementation must enforce the following invariants:

1. **Transaction Integrity**:
   - `recordPracticeCompletion()` must execute inside a `BEGIN TRANSACTION` block. If inserting the attempt log succeeds but updating the FSRS card fails, the transaction is rolled back.
2. **Audio Playback Guard**:
   - Audio autoplay must be triggered by an `ExerciseController` effect or `didChangeDependencies` guard, **never** directly inside a widget's `build()` method, preventing audio loops during widget rebuilds.
3. **Copy/Guided Card Isolation**:
   - The FSRS repository must reject any attempt to update an `srs_cards` record with `exerciseType == copyKanji` or `guidedStrokeOrder`. These exercises must be redirected strictly to `writing_metrics`.
4. **Offline Voice Absence**:
   - If `isJapaneseVoiceAvailable()` returns `false`, the app must present a banner explaining how to install Japanese speech data in device settings, while keeping all writing and non-audio recognition exercises fully functional.
