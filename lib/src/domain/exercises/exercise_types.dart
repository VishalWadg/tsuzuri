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

  /// String key stored in SQLite database (srs_cards / review_logs) for Schema v2.
  ///
  /// In Milestone 1, only [writingRecall] maps to Schema v2 ('writing').
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

  /// String key stored in SQLite database for Schema v3 multi-skill cards.
  String get v3DbKey {
    switch (this) {
      case SkillType.writingRecall:
        return 'writing';
      case SkillType.meaningRecognition:
        return 'meaning_rec';
      case SkillType.readingRecognition:
        return 'reading_rec';
      case SkillType.listeningRecognition:
        return 'listening_rec';
      case SkillType.writingDiagnostic:
        return 'writing_diag';
    }
  }
}

/// The specific exercise variation.
enum ExerciseType {
  // Writing Variations
  meaningToKanji,
  audioToKanji,
  referenceCopy,
  guidedStrokeWriting,

  // Recognition Variations
  kanjiToMeaning,
  kanjiToReading,
  audioToMeaning,
  meaningToReading;

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
