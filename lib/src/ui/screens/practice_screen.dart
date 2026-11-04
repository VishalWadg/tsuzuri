import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models.dart';
import '../../domain/exercises/exercise_answer_method.dart';
import '../../domain/exercises/exercise_definition.dart';
import '../../domain/exercises/exercise_result.dart';
import '../../domain/exercises/exercise_types.dart';
import '../../providers/app_providers.dart';
import '../../scheduling/fsrs_scheduler.dart';
import '../../services/exercise_engine.dart';
import '../canvas/kanji_canvas.dart';
import '../widgets/exercise_prompt_view.dart';
import '../widgets/multiple_choice_card.dart';

class PracticeScreen extends ConsumerStatefulWidget {
  final List<PracticeQueueItem>? queue;
  final List<ExerciseDefinition>? exercises;

  const PracticeScreen({
    super.key,
    this.queue,
    this.exercises,
  }) : assert(
          (queue != null) ^ (exercises != null),
          'Exactly one of queue or exercises must be provided',
        );

  @override
  ConsumerState<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends ConsumerState<PracticeScreen> {
  int _currentIndex = 0;
  bool _characterCompleted = false;
  PracticeGrade? _derivedGrade;
  DateTime? _nextDueDate;
  int _lastMistakes = 0;
  int _lastHints = 0;
  int? _selectedOptionIndex;

  int get _totalCount => widget.exercises?.length ?? widget.queue!.length;

  ExerciseDefinition _resolveCurrentExercise(AppSettings settings) {
    if (widget.exercises != null) {
      return widget.exercises![_currentIndex];
    }
    return ExerciseEngine.fromQueueItem(
      item: widget.queue![_currentIndex],
      settings: settings,
    );
  }

  void _handleKanjiCompleted(int mistakes, int hintsUsed) {
    final settings = ref.read(settingsProvider);
    final exercise = _resolveCurrentExercise(settings);

    final result = ExerciseResult(
      exerciseId: exercise.id,
      exerciseType: exercise.exerciseType,
      codepoint: exercise.character.codepoint,
      literal: exercise.character.literal,
      isCompleted: true,
      mistakes: mistakes,
      hintsUsed: hintsUsed,
      elapsed: Duration.zero,
    );

    _recordResultToFsrs(result);
  }

  void _handleOptionSelected(int index, bool isCorrect) {
    final settings = ref.read(settingsProvider);
    final exercise = _resolveCurrentExercise(settings);

    setState(() {
      _selectedOptionIndex = index;
    });

    final mistakes = isCorrect ? 0 : 3;
    final result = ExerciseResult(
      exerciseId: exercise.id,
      exerciseType: exercise.exerciseType,
      codepoint: exercise.character.codepoint,
      literal: exercise.character.literal,
      isCompleted: true,
      mistakes: mistakes,
      hintsUsed: 0,
      elapsed: Duration.zero,
    );

    _recordResultToFsrs(result);
  }

  void _recordResultToFsrs(ExerciseResult result) {
    final userDb = ref.read(userDatabaseProvider);
    final scheduler = ref.read(fsrsSchedulerProvider);
    final settings = ref.read(settingsProvider);
    final exercise = _resolveCurrentExercise(settings);

    final isAssistedPractice = result.exerciseType == ExerciseType.referenceCopy ||
        result.exerciseType == ExerciseType.guidedStrokeWriting;

    final grade = FsrsSchedulerService.deriveGrade(
      mistakes: result.mistakes,
      hintsUsed: result.hintsUsed,
    );

    DateTime? nextDue;
    if (!isAssistedPractice) {
      final updatedCard = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: result.codepoint,
        mistakes: result.mistakes,
        hintsUsed: result.hintsUsed,
        mode: exercise.skillType.v3DbKey,
      );
      nextDue = updatedCard.dueDate.toLocal();
    } else {
      // Assisted practice (copy / guided): log review attempt without inflating free-recall SRS interval
      userDb.insertReviewLog(
        codepoint: result.codepoint,
        mode: result.exerciseType.name,
        rating: 3,
        mistakes: result.mistakes,
        hintsUsed: result.hintsUsed,
        reviewedAt: DateTime.now(),
      );
      userDb.insertWritingMetric(
        codepoint: result.codepoint,
        exerciseType: result.exerciseType.name,
        shapeScore: 1.0,
        orderErrors: result.mistakes,
        retries: 0,
        durationMs: 0,
        recordedAt: DateTime.now(),
      );
    }

    // Refresh home screen providers
    ref.read(progressRefreshTriggerProvider.notifier).state++;

    setState(() {
      _characterCompleted = true;
      _derivedGrade = grade;
      _nextDueDate = nextDue;
      _lastMistakes = result.mistakes;
      _lastHints = result.hintsUsed;
    });
  }

  void _advanceToNext() {
    if (_currentIndex + 1 < _totalCount) {
      setState(() {
        _currentIndex++;
        _characterCompleted = false;
        _derivedGrade = null;
        _nextDueDate = null;
        _selectedOptionIndex = null;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final exercise = _resolveCurrentExercise(settings);
    final character = exercise.character;
    final answerMethod = exercise.answerMethod;

    return Scaffold(
      appBar: AppBar(
        title: Text('${exercise.activity.displayName} (${_currentIndex + 1} / $_totalCount)'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Decoupled Prompt Card: Meanings, Readings, Stroke Count
              ExercisePromptView(
                prompt: exercise.prompt,
                exerciseId: exercise.id,
              ),
              const SizedBox(height: 12),

              if (answerMethod is HandwritingAnswerMethod)
                KanjiWritingCanvas(
                  key: ValueKey('${character.codepoint}_$_currentIndex'),
                  referenceStrokes: answerMethod.referenceStrokes,
                  leniency: answerMethod.leniency,
                  hintsEnabled: answerMethod.hintsEnabled,
                  hapticsEnabled: answerMethod.hapticsEnabled,
                  showFullReference: answerMethod.showFullReference,
                  guidedMode: answerMethod.guidedMode,
                  onCompleted: _handleKanjiCompleted,
                )
              else if (answerMethod is MultipleChoiceAnswerMethod)
                MultipleChoiceCard(
                  key: ValueKey('${character.codepoint}_$_currentIndex'),
                  answerMethod: answerMethod,
                  hasAnswered: _characterCompleted,
                  selectedIndex: _selectedOptionIndex,
                  onOptionSelected: _handleOptionSelected,
                ),

              if (_characterCompleted && _derivedGrade != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: const Color(0xFFE8F5E9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Completed「${character.literal}」— FSRS Grade: ${_derivedGrade!.label}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Color(0xFF1B5E20),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Mistakes: $_lastMistakes • Hints used: $_lastHints • '
                          'Next review: ${_nextDueDate?.toString().substring(0, 16) ?? "Scheduled"}',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _advanceToNext,
                          icon: Icon(
                            _currentIndex + 1 < _totalCount
                                ? Icons.arrow_forward
                                : Icons.check_circle_outline,
                          ),
                          label: Text(
                            _currentIndex + 1 < _totalCount
                                ? 'Next Kanji'
                                : 'Finish Session',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
