import 'package:flutter/material.dart';

/// In-app Attributions Screen required by Fix #10 and Phase 6 of the Approach Plan.
class AttributionsScreen extends StatelessWidget {
  const AttributionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data Attributions & Licenses')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _AttributionCard(
            title: 'KanjiVG (Stroke Order & Vector Paths)',
            license: 'Creative Commons Attribution-ShareAlike 3.0 Unported (CC BY-SA 3.0)',
            copyrightHolder: '© Ulrich Apel (http://kanjivg.tagaini.net)',
            description:
                'KanjiVG provides the 109×109 SVG stroke paths, stroke order sequences, '
                'and stroke type classifications used by the writing canvas and pre-sampled '
                '50-point Fréchet stroke matcher.',
          ),
          SizedBox(height: 12),
          _AttributionCard(
            title: 'KANJIDIC2 (Kanji Readings, Meanings & Metadata)',
            license: 'Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)',
            copyrightHolder:
                '© Electronic Dictionary Research and Development Group (EDRDG) — Jim Breen',
            description:
                'KANJIDIC2 provides the character literals, Unicode codepoints, stroke counts, '
                'school grades, JLPT levels, frequency rankings, on\'yomi/kun\'yomi readings, '
                'and English meanings.',
          ),
          SizedBox(height: 12),
          _AttributionCard(
            title: 'FSRS (Free Spaced Repetition Scheduler)',
            license: 'MIT License',
            copyrightHolder: 'Open-Spaced-Repetition Contributors (pub.dev/packages/fsrs)',
            description:
                'Schedules review intervals per (codepoint, mode) card based on stroke mistakes '
                'and hints used during practice.',
          ),
        ],
      ),
    );
  }
}

class _AttributionCard extends StatelessWidget {
  final String title;
  final String license;
  final String copyrightHolder;
  final String description;

  const _AttributionCard({
    required this.title,
    required this.license,
    required this.copyrightHolder,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              copyrightHolder,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 2),
            Text(
              'License: $license',
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(description),
          ],
        ),
      ),
    );
  }
}
