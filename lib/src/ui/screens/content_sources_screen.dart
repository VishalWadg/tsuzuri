import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../content/ingestion/models/ingestion_result.dart';
import '../../content/providers/content_source_providers.dart';
import '../../data/models.dart';
import '../../providers/app_providers.dart';

/// Screen allowing learners to manage modular Kanji, stroke, and audio sources
/// (offline `.zip`/`.json` packages and online HTTP manifests), adjust fallback priorities,
/// and inspect the permanently anchored bundled defaults.
class ContentSourcesScreen extends ConsumerStatefulWidget {
  const ContentSourcesScreen({super.key});

  @override
  ConsumerState<ContentSourcesScreen> createState() => _ContentSourcesScreenState();
}

class _ContentSourcesScreenState extends ConsumerState<ContentSourcesScreen> {
  bool _isBusy = false;
  String? _busyMessage;

  Future<void> _importOfflinePackage() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip', 'json'],
    );
    if (picked == null || picked.files.single.path == null) return;

    final file = File(picked.files.single.path!);
    final ext = p.extension(file.path).toLowerCase();

    await _runWithProgress('Validating & importing package...', () async {
      final manager = ref.read(contentSourceManagerProvider);
      if (ext == '.json') {
        return manager.importJsonFile(file);
      }
      return manager.importArchiveFile(file);
    });
  }

  Future<void> _promptConnectOnlineSource() async {
    final urlText = await showDialog<String>(
      context: context,
      builder: (_) => const _ConnectOnlineSourceDialog(),
    );

    if (urlText == null || urlText.isEmpty) return;

    final uri = Uri.tryParse(urlText);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      if (mounted) {
        _showErrorDialog(
          title: 'Invalid URL',
          message: 'Please enter a valid http:// or https:// URL pointing to manifest.json.',
        );
      }
      return;
    }

    await _runWithProgress('Fetching remote manifest...', () async {
      final manager = ref.read(contentSourceManagerProvider);
      return manager.connectOnlineUrl(uri);
    });
  }

  Future<void> _refreshOnlineSource(InstalledSourceRecord record) async {
    await _runWithProgress('Syncing updates for "${record.name}"...', () async {
      return ref.read(contentSourceManagerProvider).refreshOnlineSource(record.sourceId);
    });
  }

  Future<void> _confirmRemoveSource(InstalledSourceRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove "${record.name}"?'),
        content: const Text(
          'This removes the local package files from your device.\n\n'
          'Your FSRS spaced-repetition progress, review logs, and study stability '
          'for characters in this source stay 100% preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _runVoidAction(() async {
      await ref.read(contentSourceManagerProvider).removeSource(record.sourceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed "${record.name}" (FSRS progress kept intact).')),
        );
      }
    });
  }

  Future<void> _runWithProgress(
    String statusMessage,
    Future<IngestionResult> Function() action,
  ) async {
    setState(() {
      _isBusy = true;
      _busyMessage = statusMessage;
    });

    try {
      final result = await action();
      ref.read(progressRefreshTriggerProvider.notifier).state++;
      if (!mounted) return;

      if (result.isSuccess && result.manifest != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Installed "${result.manifest!.name}" v${result.manifest!.version}',
            ),
          ),
        );
      } else {
        _showErrorDialog(
          title: 'Package Rejected (${result.errorCode?.name ?? 'error'})',
          message: result.errorMessage ?? 'Unable to load source package.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _runVoidAction(Future<void> Function() action) async {
    setState(() => _isBusy = true);
    try {
      await action();
      ref.read(progressRefreshTriggerProvider.notifier).state++;
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _showErrorDialog({required String title, required String message}) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 17))),
          ],
        ),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final installedSources = ref.watch(installedSourcesProvider);
    final manager = ref.read(contentSourceManagerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Content Sources & Packs')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildAddSourceCard(theme),
              const SizedBox(height: 20),

              Row(
                children: [
                  const Icon(Icons.layers_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Active Priority Stack',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Higher sources override lower ones per character. Missing Kanji metadata, '
                'strokes, or audio automatically fall back to bundled defaults.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),

              if (installedSources.isEmpty)
                Card(
                  elevation: 0,
                  color: theme.colorScheme.surfaceContainerLow,
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No custom sources added yet. Import an offline .zip / .json pack '
                      'or connect an online manifest URL above.',
                    ),
                  ),
                )
              else
                ...List.generate(installedSources.length, (index) {
                  final record = installedSources[index];
                  return _CustomSourceTile(
                    record: record,
                    rankNumber: index + 1,
                    canMoveUp: index > 0 && !_isBusy,
                    canMoveDown: index + 1 < installedSources.length && !_isBusy,
                    onToggleEnabled: _isBusy
                        ? null
                        : (val) => _runVoidAction(() => manager.setSourceEnabled(record.sourceId, val)),
                    onMoveUp: () => _runVoidAction(
                      () => manager.moveSourcePriority(record.sourceId, moveUp: true),
                    ),
                    onMoveDown: () => _runVoidAction(
                      () => manager.moveSourcePriority(record.sourceId, moveUp: false),
                    ),
                    onRefresh: record.originType == SourceOriginType.onlineUrl && !_isBusy
                        ? () => _refreshOnlineSource(record)
                        : null,
                    onRemove: _isBusy ? null : () => _confirmRemoveSource(record),
                  );
                }),

              const SizedBox(height: 8),
              _buildBundledDefaultsCard(theme),
            ],
          ),

          if (_isBusy)
            Positioned.fill(
              child: Container(
                color: Colors.black45,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (_busyMessage != null) ...[
                            const SizedBox(height: 14),
                            Text(_busyMessage!),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAddSourceCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Plug-and-Play Custom Sources',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'Layer community or personal Kanji dictionaries, stroke packages, and '
              'custom native audio packs on top of built-in defaults.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('import_offline_package_btn'),
                    onPressed: _isBusy ? null : _importOfflinePackage,
                    icon: const Icon(Icons.folder_zip_outlined),
                    label: const Text('Import Pack (.zip / .json)'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('connect_online_source_btn'),
                    onPressed: _isBusy ? null : _promptConnectOnlineSource,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('Connect URL'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBundledDefaultsCard(ThemeData theme) {
    return Card(
      key: const Key('bundled_defaults_card'),
      elevation: 0,
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Bundled Defaults (Base Fallback)',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const Chip(
                  label: Text('Always Active'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'KANJIDIC2 Metadata • KanjiVG 50-Point Strokes • Device ja-JP TTS',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            const Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _CapabilityChip(label: 'metadata'),
                _CapabilityChip(label: 'strokes'),
                _CapabilityChip(label: 'audio'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomSourceTile extends StatelessWidget {
  final InstalledSourceRecord record;
  final int rankNumber;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool>? onToggleEnabled;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback? onRefresh;
  final VoidCallback? onRemove;

  const _CustomSourceTile({
    required this.record,
    required this.rankNumber,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onToggleEnabled,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRefresh,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key('source_card_${record.sourceId}'),
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: record.enabled
              ? theme.colorScheme.primary.withValues(alpha: 0.45)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: record.enabled
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Text(
                    '#$rankNumber',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${record.name} (v${record.version})',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        record.originUri != null
                            ? '${record.originType.label} • ${record.originUri}'
                            : record.originType.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: Key('source_toggle_${record.sourceId}'),
                  value: record.enabled,
                  onChanged: onToggleEnabled,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: record.capabilities
                  .map((cap) => _CapabilityChip(label: cap))
                  .toList(growable: false),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  key: Key('source_up_${record.sourceId}'),
                  tooltip: 'Move higher in priority',
                  onPressed: canMoveUp ? onMoveUp : null,
                  icon: const Icon(Icons.arrow_upward, size: 19),
                ),
                IconButton(
                  key: Key('source_down_${record.sourceId}'),
                  tooltip: 'Move lower in priority',
                  onPressed: canMoveDown ? onMoveDown : null,
                  icon: const Icon(Icons.arrow_downward, size: 19),
                ),
                if (onRefresh != null)
                  IconButton(
                    key: Key('source_refresh_${record.sourceId}'),
                    tooltip: 'Sync remote updates',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, size: 19),
                  ),
                IconButton(
                  key: Key('source_delete_${record.sourceId}'),
                  tooltip: 'Remove source',
                  onPressed: onRemove,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  final String label;
  const _CapabilityChip({required this.label});

  IconData _icon() {
    switch (label.toLowerCase()) {
      case 'metadata':
        return Icons.translate;
      case 'strokes':
        return Icons.gesture;
      case 'audio':
        return Icons.volume_up_outlined;
      default:
        return Icons.extension;
    }
  }

  @override
  Widget build(BuildContext context) {
    final formatted = label.isEmpty ? '' : '${label[0].toUpperCase()}${label.substring(1)}';
    return Chip(
      avatar: Icon(_icon(), size: 14),
      label: Text(formatted, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}

class _ConnectOnlineSourceDialog extends StatefulWidget {
  const _ConnectOnlineSourceDialog();

  @override
  State<_ConnectOnlineSourceDialog> createState() => _ConnectOnlineSourceDialogState();
}

class _ConnectOnlineSourceDialogState extends State<_ConnectOnlineSourceDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Connect Online Source'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter the direct URL to a remote source manifest (manifest.json). '
            'Validated assets are cached locally for offline practice.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('online_url_textfield'),
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Manifest URL',
              hintText: 'https://example.com/kanji-pack/manifest.json',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('connect_url_submit_btn'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Fetch & Install'),
        ),
      ],
    );
  }
}
