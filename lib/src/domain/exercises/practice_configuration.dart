import '../../data/models.dart';
import '../../matching/stroke_matcher.dart';
import 'exercise_types.dart';

/// Configuration parameters governing a practice session or exercise.
class PracticeConfiguration {
  final ExerciseType exerciseType;
  final LeniencyPreset leniency;
  final bool hintsEnabled;
  final bool hapticsEnabled;
  final AudioSpeed audioSpeed;
  final bool audioAutoplay;
  final int cardLimit;

  const PracticeConfiguration({
    this.exerciseType = ExerciseType.meaningToKanji,
    this.leniency = LeniencyPreset.normal,
    this.hintsEnabled = true,
    this.hapticsEnabled = true,
    this.audioSpeed = AudioSpeed.normal,
    this.audioAutoplay = true,
    this.cardLimit = 10,
  }) : assert(cardLimit > 0, 'cardLimit must be greater than 0');

  PracticeConfiguration copyWith({
    ExerciseType? exerciseType,
    LeniencyPreset? leniency,
    bool? hintsEnabled,
    bool? hapticsEnabled,
    AudioSpeed? audioSpeed,
    bool? audioAutoplay,
    int? cardLimit,
  }) {
    return PracticeConfiguration(
      exerciseType: exerciseType ?? this.exerciseType,
      leniency: leniency ?? this.leniency,
      hintsEnabled: hintsEnabled ?? this.hintsEnabled,
      hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
      audioSpeed: audioSpeed ?? this.audioSpeed,
      audioAutoplay: audioAutoplay ?? this.audioAutoplay,
      cardLimit: cardLimit ?? this.cardLimit,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PracticeConfiguration &&
          runtimeType == other.runtimeType &&
          exerciseType == other.exerciseType &&
          leniency == other.leniency &&
          hintsEnabled == other.hintsEnabled &&
          hapticsEnabled == other.hapticsEnabled &&
          audioSpeed == other.audioSpeed &&
          audioAutoplay == other.audioAutoplay &&
          cardLimit == other.cardLimit;

  @override
  int get hashCode => Object.hash(
        exerciseType,
        leniency,
        hintsEnabled,
        hapticsEnabled,
        audioSpeed,
        audioAutoplay,
        cardLimit,
      );

  @override
  String toString() =>
      'PracticeConfiguration(type: $exerciseType, leniency: ${leniency.name}, hints: $hintsEnabled, limit: $cardLimit)';
}

/// A pre-packaged, opinionated practice preset tailored for a specific learning goal.
class PracticePreset {
  final String id;
  final String name;
  final String description;
  final PracticeConfiguration configuration;

  const PracticePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.configuration,
  });

  /// Standard spaced-repetition daily review with meaning prompt and balanced leniency.
  static const PracticePreset standard = PracticePreset(
    id: 'standard',
    name: 'Standard Review',
    description: 'Balanced spaced-repetition daily writing practice.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.meaningToKanji,
      leniency: LeniencyPreset.normal,
      hintsEnabled: true,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.normal,
      audioAutoplay: true,
      cardLimit: 10,
    ),
  );

  /// Beginner-friendly guided practice with stroke-by-stroke outlines and slow audio.
  static const PracticePreset beginner = PracticePreset(
    id: 'beginner',
    name: 'Beginner Friendly',
    description: 'Guided stroke-by-stroke assistance for new learners.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.guidedStrokeWriting,
      leniency: LeniencyPreset.forgiving,
      hintsEnabled: true,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.slow,
      audioAutoplay: true,
      cardLimit: 5,
    ),
  );

  /// Mastery challenge with strict stroke thresholds and hints disabled.
  static const PracticePreset challenge = PracticePreset(
    id: 'challenge',
    name: 'Mastery Challenge',
    description: 'Strict evaluation with hints disabled to test true recall.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.meaningToKanji,
      leniency: LeniencyPreset.strict,
      hintsEnabled: false,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.normal,
      audioAutoplay: true,
      cardLimit: 15,
    ),
  );

  /// Oral prompt testing audio-to-character recall.
  static const PracticePreset audio = PracticePreset(
    id: 'audio',
    name: 'Audio Immersion',
    description: 'Oral reading prompt testing sound-to-character recall.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.audioToKanji,
      leniency: LeniencyPreset.normal,
      hintsEnabled: true,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.normal,
      audioAutoplay: true,
      cardLimit: 10,
    ),
  );

  /// Muscle-memory tracing with faint reference watermark on canvas background.
  static const PracticePreset copy = PracticePreset(
    id: 'copy',
    name: 'Motor Tracing',
    description: 'Faint watermark on canvas background for muscle memory.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.referenceCopy,
      leniency: LeniencyPreset.forgiving,
      hintsEnabled: true,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.normal,
      audioAutoplay: true,
      cardLimit: 5,
    ),
  );

  /// Multiple-choice recognition of English meanings from Kanji characters.
  static const PracticePreset recMeaning = PracticePreset(
    id: 'rec_meaning',
    name: 'Kanji → Meaning',
    description: 'Multiple-choice recognition of English meanings from Kanji characters.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.kanjiToMeaning,
      leniency: LeniencyPreset.normal,
      hintsEnabled: true,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.normal,
      audioAutoplay: true,
      cardLimit: 10,
    ),
  );

  /// Multiple-choice recognition of kana readings from Kanji characters.
  static const PracticePreset recReading = PracticePreset(
    id: 'rec_reading',
    name: 'Kanji → Reading',
    description: 'Multiple-choice recognition of on\'yomi and kun\'yomi kana readings.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.kanjiToReading,
      leniency: LeniencyPreset.normal,
      hintsEnabled: true,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.normal,
      audioAutoplay: true,
      cardLimit: 10,
    ),
  );

  /// Multiple-choice recognition of English meanings from spoken Japanese audio.
  static const PracticePreset recAudio = PracticePreset(
    id: 'rec_audio',
    name: 'Audio → Meaning',
    description: 'Multiple-choice recognition of meanings from spoken Japanese audio.',
    configuration: PracticeConfiguration(
      exerciseType: ExerciseType.audioToMeaning,
      leniency: LeniencyPreset.normal,
      hintsEnabled: true,
      hapticsEnabled: true,
      audioSpeed: AudioSpeed.normal,
      audioAutoplay: true,
      cardLimit: 10,
    ),
  );

  /// Complete built-in catalog of standard writing presets.
  static const List<PracticePreset> standardPresets = [
    standard,
    beginner,
    challenge,
    audio,
    copy,
  ];

  /// Complete built-in catalog of recognition presets.
  static const List<PracticePreset> recognitionPresets = [
    recMeaning,
    recReading,
    recAudio,
  ];

  /// All available built-in presets across all activities.
  static const List<PracticePreset> allPresets = [
    ...standardPresets,
    ...recognitionPresets,
  ];

  /// Returns presets that match the given [activity] (Writing or Recognition).
  static List<PracticePreset> presetsForActivity(ExerciseActivity activity) {
    return allPresets.where((p) => p.activity == activity).toList();
  }

  /// Broad activity category of this preset.
  ExerciseActivity get activity => configuration.exerciseType.activity;

  /// Resolves a preset by [id], falling back to [standard] if unrecognized.
  static PracticePreset getById(String id) {
    return allPresets.firstWhere(
      (p) => p.id == id,
      orElse: () => standard,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PracticePreset &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          description == other.description &&
          configuration == other.configuration;

  @override
  int get hashCode => Object.hash(id, name, description, configuration);

  @override
  String toString() => 'PracticePreset(id: $id, name: $name)';
}
