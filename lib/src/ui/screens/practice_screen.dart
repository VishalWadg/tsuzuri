import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/app_providers.dart';
import '../../scheduling/fsrs_scheduler.dart';
import '../canvas/kanji_canvas.dart';

class PracticeScreen extends ConsumerStatefulWidget {
  final List<PracticeQueueItem> queue;

  const PracticeScreen({
    super.key,
    required this.queue,
  });

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

  void _handleKanjiCompleted(int mistakes, int hintsUsed) {
    final item = widget.queue[_currentIndex];
    final userDb = ref.read(userDatabaseProvider);
    final scheduler = ref.read(fsrsSchedulerProvider);

    final grade = FsrsSchedulerService.deriveGrade(
      mistakes: mistakes,
      hintsUsed: hintsUsed,
    );
    final updatedCard = scheduler.recordPracticeCompletion(
      userDb: userDb,
      codepoint: item.kanji.codepoint,
      mistakes: mistakes,
      hintsUsed: hintsUsed,
    );

    // Refresh home screen providers
    ref.read(progressRefreshTriggerProvider.notifier).state++;

    setState(() {
      _characterCompleted = true;
      _derivedGrade = grade;
      _nextDueDate = updatedCard.dueDate.toLocal();
      _lastMistakes = mistakes;
      _lastHints = hintsUsed;
    });
  }

  void _advanceToNext() {
    if (_currentIndex + 1 < widget.queue.length) {
      setState(() {
        _currentIndex++;
        _characterCompleted = false;
        _derivedGrade = null;
        _nextDueDate = null;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final item = widget.queue[_currentIndex];
    final kanji = item.kanji;

    return Scaffold(
      appBar: AppBar(
        title: Text('Writing Practice (${_currentIndex + 1} / ${widget.queue.length})'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Prompt Card: Meanings, Readings, Stroke Count (Section 4)
              Card(
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
                              kanji.meanings.join(', '),
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ),
                          Chip(
                            label: Text('${kanji.strokeCount} strokes'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (kanji.onyomi.isNotEmpty)
                        Text('On\'yomi: ${kanji.onyomi.join(" ・ ")}'),
                      if (kanji.kunyomi.isNotEmpty)
                        Text('Kun\'yomi: ${kanji.kunyomi.join(" ・ ")}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 3-Layer CustomPainter Canvas
              KanjiWritingCanvas(
                key: ValueKey(kanji.codepoint),
                referenceStrokes: kanji.strokes,
                leniency: settings.leniency,
                hintsEnabled: settings.hintsEnabled,
                hapticsEnabled: settings.hapticsEnabled,
                onCompleted: _handleKanjiCompleted,
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
                          'Completed「${kanji.literal}」— FSRS Grade: ${_derivedGrade!.label}',
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
                            _currentIndex + 1 < widget.queue.length
                                ? Icons.arrow_forward
                                : Icons.check_circle_outline,
                          ),
                          label: Text(
                            _currentIndex + 1 < widget.queue.length
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
