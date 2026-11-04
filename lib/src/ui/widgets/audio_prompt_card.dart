import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models.dart';
import '../../domain/exercises/exercise_prompt.dart';
import '../../providers/app_providers.dart';

/// Interactive UI widget that plays audio prompts for Audio → Write Kanji exercises.
///
/// Features:
/// - Replay button supporting unlimited replays.
/// - Playback speed toggle (Normal / Slow).
/// - Autoplay guard that prevents audio from re-triggering during widget rebuilds.
/// - Expandable meaning hint for learner assistance.
/// - Warning banner when Japanese voice data is unavailable.
class AudioPromptCard extends ConsumerStatefulWidget {
  final AudioPrompt prompt;
  final String exerciseId;

  const AudioPromptCard({
    super.key,
    required this.prompt,
    required this.exerciseId,
  });

  @override
  ConsumerState<AudioPromptCard> createState() => _AudioPromptCardState();
}

class _AudioPromptCardState extends ConsumerState<AudioPromptCard> {
  String? _lastAutoplayedExerciseId;
  bool _showMeaningHint = false;
  AudioSpeed? _overrideSpeed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndAutoplay());
  }

  @override
  void didUpdateWidget(covariant AudioPromptCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exerciseId != widget.exerciseId) {
      _showMeaningHint = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndAutoplay());
    }
  }

  void _checkAndAutoplay() {
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    if (settings.audioAutoplay && _lastAutoplayedExerciseId != widget.exerciseId) {
      _lastAutoplayedExerciseId = widget.exerciseId;
      _playAudio();
    }
  }

  void _playAudio() {
    final settings = ref.read(settingsProvider);
    final speed = _overrideSpeed ?? settings.audioSpeed;
    final speechService = ref.read(speechServiceProvider);
    speechService.speakJapanese(widget.prompt.spokenText, rate: speed.rate);
  }

  void _toggleSpeed() {
    final currentSpeed = _overrideSpeed ?? ref.read(settingsProvider).audioSpeed;
    setState(() {
      _overrideSpeed = currentSpeed == AudioSpeed.normal ? AudioSpeed.slow : AudioSpeed.normal;
    });
    // Immediately play at new speed for feedback
    _playAudio();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final activeSpeed = _overrideSpeed ?? settings.audioSpeed;
    final voiceAvailableAsync = ref.watch(japaneseVoiceAvailableProvider);

    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Voice unavailable warning banner
            voiceAvailableAsync.when(
              data: (available) {
                if (!available) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFFB74D)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Color(0xFFE65100), size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Japanese TTS voice not found. Please enable ja-JP TTS in system settings.',
                            style: TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),

            // Header row with title and stroke count
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.headphones, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      'Listen & Write Kanji',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
                Chip(
                  label: Text('${widget.prompt.strokeCount} strokes'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Playback and speed action controls
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _playAudio,
                    icon: const Icon(Icons.volume_up),
                    label: const Text('Play Audio'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _toggleSpeed,
                  icon: const Icon(Icons.speed, size: 18),
                  label: Text(activeSpeed.label),
                ),
              ],
            ),
            const SizedBox(height: 4),

            // Meaning Hint toggle and display
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _showMeaningHint = !_showMeaningHint;
                  });
                },
                icon: Icon(
                  _showMeaningHint ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 16,
                ),
                label: Text(
                  _showMeaningHint ? 'Hide Meaning' : 'Show Meaning Hint',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            if (_showMeaningHint && widget.prompt.hiddenMeanings.isNotEmpty) ...[
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Meaning: ${widget.prompt.hiddenMeanings.join(", ")}',
                  style: TextStyle(
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
