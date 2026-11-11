import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../content/providers/content_source_providers.dart';
import '../../data/models.dart';
import '../../domain/exercises/exercise_types.dart';
import '../../providers/app_providers.dart';
import '../../services/exercise_engine.dart';
import '../widgets/preset_selector_widget.dart';
import 'attributions_screen.dart';
import 'content_sources_screen.dart';
import 'practice_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _startSession(
    BuildContext context,
    WidgetRef ref,
    List<KanjiCharacter> characters,
  ) async {
    final activeConfig = ref.read(activeConfigurationProvider);
    final repository = ref.read(contentRepositoryProvider);
    final contentDb = ref.read(contentDatabaseProvider);

    final exercises = await ExerciseEngine.createSessionQueueAsync(
      characters: characters,
      config: activeConfig,
      repository: repository,
      contentDb: contentDb,
    );

    if (!context.mounted) return;
    if (exercises.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No characters with stroke vectors available for Writing mode. '
            'Try Recognition mode or import a stroke pack.',
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PracticeScreen(exercises: exercises),
      ),
    );
  }

  Future<void> _practiceSingleKanji(
    BuildContext context,
    WidgetRef ref,
    KanjiCharacter kanji,
  ) async {
    final activeConfig = ref.read(activeConfigurationProvider);
    if (activeConfig.exerciseType.activity == ExerciseActivity.writing &&
        kanji.strokes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No stroke data for 「${kanji.literal}」. Switch to Recognition mode or import a stroke pack.',
          ),
        ),
      );
      return;
    }

    final repository = ref.read(contentRepositoryProvider);
    final contentDb = ref.read(contentDatabaseProvider);
    final exercise = await ExerciseEngine.createExerciseAsync(
      kanji: kanji,
      config: activeConfig,
      repository: repository,
      contentDb: contentDb,
    );

    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PracticeScreen(exercises: [exercise]),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(progressRefreshTriggerProvider);
    ref.watch(contentSourceRegistryVersionProvider);
    final contentDb = ref.watch(contentDatabaseProvider);
    final userDb = ref.watch(userDatabaseProvider);
    final queue = ref.watch(dailyQueueProvider);
    final activePreset = ref.watch(activePresetProvider);
    final installedSources = ref.watch(installedSourcesProvider);
    final activeCustomCount = installedSources.where((s) => s.enabled).length;

    final dueCount = userDb.getDueCards(now: DateTime.now()).length;
    final studiedCount = userDb.getStudiedCodepoints().length;
    final allKanji = ref.watch(allKanjiOrderedProvider).maybeWhen(
          data: (list) => list,
          orElse: () => contentDb.getAllKanjiOrdered(),
        );
    final totalKanji = allKanji.length;

    final eligibleChars = activePreset.configuration.exerciseType.activity ==
            ExerciseActivity.writing
        ? queue.map((q) => q.kanji).where((k) => k.strokes.isNotEmpty).toList()
        : queue.map((q) => q.kanji).toList();
    final sessionLength =
        eligibleChars.take(activePreset.configuration.cardLimit).length;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/logo.png',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'TSUZURI',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                fontSize: 19,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '綴り',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings & Backup',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Data Sources & Licenses',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AttributionsScreen()),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Summary Card
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Daily Writing Queue',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _StatBadge(
                        label: 'Due Now',
                        value: '$dueCount',
                        color: const Color(0xFFC62828),
                      ),
                      const SizedBox(width: 12),
                      _StatBadge(
                        label: 'In Queue',
                        value: '${queue.length}',
                        color: const Color(0xFF1565C0),
                      ),
                      const SizedBox(width: 12),
                      _StatBadge(
                        label: 'Studied',
                        value: '$studiedCount / $totalKanji',
                        color: const Color(0xFF2E7D32),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const PresetSelectorWidget(),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: queue.isEmpty
                          ? null
                          : () => _startSession(
                                context,
                                ref,
                                queue.map((q) => q.kanji).toList(),
                              ),
                      icon: const Icon(Icons.edit_note),
                      label: Text(
                        queue.isEmpty
                            ? 'All Caught Up for Today!'
                            : 'Start ${activePreset.name} ($sessionLength Kanji)',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Kanji Deck (Tap any character to practice)',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              TextButton.icon(
                key: const Key('home_manage_sources_btn'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const ContentSourcesScreen()),
                  );
                },
                icon: const Icon(Icons.extension_outlined, size: 18),
                label: Text(
                  activeCustomCount == 0 ? 'Sources' : 'Sources ($activeCustomCount)',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.92,
            ),
            itemCount: allKanji.length,
            itemBuilder: (context, index) {
              final kanji = allKanji[index];
              final card = userDb.getCard(kanji.codepoint);
              return _KanjiGridTile(
                kanji: kanji,
                progress: card,
                onTap: () => _practiceSingleKanji(context, ref, kanji),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatBadge({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.30)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _KanjiGridTile extends StatelessWidget {
  final KanjiCharacter kanji;
  final UserCardProgress? progress;
  final VoidCallback onTap;

  const _KanjiGridTile({
    required this.kanji,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isStudied = progress != null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isStudied ? const Color(0xFF2E7D32) : Colors.grey.shade300,
            width: isStudied ? 1.6 : 1.0,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              kanji.literal,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              kanji.meanings.isNotEmpty ? kanji.meanings.first : '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
