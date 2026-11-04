import 'package:flutter/material.dart';
import '../../domain/exercises/exercise_prompt.dart';
import 'audio_prompt_card.dart';

/// Composable UI widget responsible for rendering an [ExercisePrompt].
///
/// Exhaustively switches over sealed variants of [ExercisePrompt].
class ExercisePromptView extends StatelessWidget {
  final ExercisePrompt prompt;
  final String? exerciseId;

  const ExercisePromptView({
    super.key,
    required this.prompt,
    this.exerciseId,
  });

  @override
  Widget build(BuildContext context) {
    return switch (prompt) {
      final MeaningPrompt meaningPrompt => _buildMeaningPromptCard(context, meaningPrompt),
      final AudioPrompt audioPrompt => AudioPromptCard(
          prompt: audioPrompt,
          exerciseId: exerciseId ?? 'audio_${audioPrompt.codepoint}',
        ),
      final KanjiPrompt kanjiPrompt => _buildKanjiPromptCard(context, kanjiPrompt),
    };
  }

  Widget _buildKanjiPromptCard(BuildContext context, KanjiPrompt kanjiPrompt) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                kanjiPrompt.literal,
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 64,
                    ),
              ),
              const SizedBox(height: 8),
              Chip(
                label: Text('${kanjiPrompt.strokeCount} strokes'),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMeaningPromptCard(BuildContext context, MeaningPrompt meaningPrompt) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    meaningPrompt.meanings.join(', '),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Chip(
                  label: Text('${meaningPrompt.strokeCount} strokes'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (meaningPrompt.onyomi.isNotEmpty)
              Text('On\'yomi: ${meaningPrompt.onyomi.join(" ・ ")}'),
            if (meaningPrompt.kunyomi.isNotEmpty)
              Text('Kun\'yomi: ${meaningPrompt.kunyomi.join(" ・ ")}'),
          ],
        ),
      ),
    );
  }
}
