import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/exercises/exercise_types.dart';
import '../../domain/exercises/practice_configuration.dart';
import '../../providers/app_providers.dart';

/// Interactive UI component allowing learners to select their active practice preset.
class PresetSelectorWidget extends ConsumerWidget {
  const PresetSelectorWidget({super.key});

  IconData _iconForPreset(String id) {
    switch (id) {
      case 'standard':
        return Icons.edit_note;
      case 'beginner':
        return Icons.school_outlined;
      case 'challenge':
        return Icons.military_tech_outlined;
      case 'audio':
        return Icons.volume_up_outlined;
      case 'copy':
        return Icons.gesture_outlined;
      case 'rec_meaning':
        return Icons.translate_outlined;
      case 'rec_reading':
        return Icons.record_voice_over_outlined;
      case 'rec_audio':
        return Icons.hearing_outlined;
      default:
        return Icons.tune;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePreset = ref.watch(activePresetProvider);
    final theme = Theme.of(context);
    final currentActivity = activePreset.activity;
    final availablePresets = PracticePreset.presetsForActivity(currentActivity);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tune,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Practice Activity & Mode',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ExerciseActivity>(
            segments: const [
              ButtonSegment<ExerciseActivity>(
                value: ExerciseActivity.writing,
                icon: Icon(Icons.draw, size: 18),
                label: Text('Writing'),
              ),
              ButtonSegment<ExerciseActivity>(
                value: ExerciseActivity.recognition,
                icon: Icon(Icons.checklist_rtl, size: 18),
                label: Text('Recognition'),
              ),
            ],
            selected: {currentActivity},
            onSelectionChanged: (selected) {
              final newActivity = selected.first;
              if (newActivity != currentActivity) {
                if (newActivity == ExerciseActivity.writing) {
                  ref.read(activePresetProvider.notifier).selectPreset(PracticePreset.standard);
                } else {
                  ref.read(activePresetProvider.notifier).selectPreset(PracticePreset.recMeaning);
                }
              }
            },
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: availablePresets.map((preset) {
              final isSelected = preset.id == activePreset.id;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: Key('preset_chip_${preset.id}'),
                  avatar: Icon(
                    _iconForPreset(preset.id),
                    size: 18,
                    color: isSelected
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  label: Text(preset.name),
                  selected: isSelected,
                  selectedColor: theme.colorScheme.primary,
                  labelStyle: TextStyle(
                    color: isSelected
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurface,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    fontSize: 13,
                  ),
                  onSelected: (selected) {
                    if (selected) {
                      ref.read(activePresetProvider.notifier).selectPreset(preset);
                    }
                  },
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${activePreset.description} (Limit: ${activePreset.configuration.cardLimit} Kanji)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
