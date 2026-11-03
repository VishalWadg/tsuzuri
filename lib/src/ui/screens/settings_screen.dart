import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../matching/stroke_matcher.dart';
import '../../providers/app_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final userDb = ref.read(userDatabaseProvider);
    final jsonBackup = userDb.exportBackupJson();
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'kanji_user_progress_backup.json'));
    await file.writeAsString(jsonBackup, flush: true);

    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'Offline Kanji Practice Progress Backup',
    );
  }

  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    final content = await file.readAsString();
    final userDb = ref.read(userDatabaseProvider);
    userDb.importBackupJson(content);

    ref.read(settingsProvider.notifier).reloadFromDatabase();
    ref.read(progressRefreshTriggerProvider.notifier).state++;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Progress backup restored!')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings & Backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Stroke Matching Leniency',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SegmentedButton<LeniencyPreset>(
            segments: LeniencyPreset.values
                .map((preset) => ButtonSegment<LeniencyPreset>(
                      value: preset,
                      label: Text(preset.label),
                    ))
                .toList(),
            selected: {settings.leniency},
            onSelectionChanged: (sel) => notifier.updateLeniency(sel.first),
          ),
          const Divider(height: 32),

          SwitchListTile(
            title: const Text('Stroke Hints'),
            subtitle: const Text('Show faint outline and animated stroke demo after mistakes'),
            value: settings.hintsEnabled,
            onChanged: notifier.toggleHints,
          ),
          SwitchListTile(
            title: const Text('Haptic Feedback'),
            subtitle: const Text('Light vibration on stroke snap and error feedback'),
            value: settings.hapticsEnabled,
            onChanged: notifier.toggleHaptics,
          ),
          const Divider(height: 32),

          ListTile(
            title: const Text('Daily New Kanji Limit'),
            subtitle: Text('${settings.dailyNewCardsLimit} new characters per day'),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: settings.dailyNewCardsLimit.toDouble(),
                min: 1,
                max: 50,
                divisions: 49,
                label: '${settings.dailyNewCardsLimit}',
                onChanged: (v) => notifier.updateDailyNewLimit(v.round()),
              ),
            ),
          ),
          const Divider(height: 32),

          Text(
            'Offline Backup & Restore (Fix #11)',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'All FSRS scheduling cards, review logs, and settings live on your device. '
            'Export a JSON snapshot anytime to back up or transfer your progress.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _exportBackup(context, ref),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Export Backup'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _importBackup(context, ref),
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: const Text('Restore Backup'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
