import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/content_db.dart';
import '../data/models.dart';
import '../data/user_db.dart';
import '../domain/exercises/practice_configuration.dart';
import '../matching/stroke_matcher.dart';
import '../scheduling/fsrs_scheduler.dart';
import '../services/speech_service.dart';

/// Injected at startup in `main.dart` after initializing ContentDatabase and UserDatabase.
final contentDatabaseProvider = Provider<ContentDatabase>((ref) {
  throw UnimplementedError('contentDatabaseProvider must be overridden at startup');
});

final userDatabaseProvider = Provider<UserDatabase>((ref) {
  throw UnimplementedError('userDatabaseProvider must be overridden at startup');
});

final fsrsSchedulerProvider = Provider<FsrsSchedulerService>((ref) {
  return FsrsSchedulerService();
});

final speechServiceProvider = Provider<ISpeechService>((ref) {
  return SpeechService();
});

/// Reactive notifier for user settings (`leniency`, `hints`, `haptics`, `dailyNewCardsLimit`).
class SettingsNotifier extends StateNotifier<AppSettings> {
  final UserDatabase _userDb;

  SettingsNotifier(this._userDb) : super(_userDb.loadSettings());

  void updateLeniency(LeniencyPreset preset) {
    state = state.copyWith(leniency: preset);
    _userDb.saveSettings(state);
  }

  void toggleHints(bool enabled) {
    state = state.copyWith(hintsEnabled: enabled);
    _userDb.saveSettings(state);
  }

  void toggleHaptics(bool enabled) {
    state = state.copyWith(hapticsEnabled: enabled);
    _userDb.saveSettings(state);
  }

  void updateDailyNewLimit(int limit) {
    state = state.copyWith(dailyNewCardsLimit: limit.clamp(1, 100));
    _userDb.saveSettings(state);
  }

  void updateThemeMode(AppThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    _userDb.saveSettings(state);
  }

  void updateAudioSpeed(AudioSpeed speed) {
    state = state.copyWith(audioSpeed: speed);
    _userDb.saveSettings(state);
  }

  void toggleAudioAutoplay(bool enabled) {
    state = state.copyWith(audioAutoplay: enabled);
    _userDb.saveSettings(state);
  }

  void reloadFromDatabase() {
    state = _userDb.loadSettings();
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  final userDb = ref.watch(userDatabaseProvider);
  return SettingsNotifier(userDb);
});

/// Probes whether Japanese offline TTS voice data is available on the device.
final japaneseVoiceAvailableProvider = FutureProvider<bool>((ref) async {
  final speechService = ref.watch(speechServiceProvider);
  return speechService.isJapaneseVoiceAvailable();
});

/// Bump counter to refresh queue & home stats whenever a session or backup restore finishes.
final progressRefreshTriggerProvider = StateProvider<int>((ref) => 0);

/// Provides the current daily review + new-card queue.
final dailyQueueProvider = Provider<List<PracticeQueueItem>>((ref) {
  ref.watch(progressRefreshTriggerProvider);
  final settings = ref.watch(settingsProvider);
  final contentDb = ref.watch(contentDatabaseProvider);
  final userDb = ref.watch(userDatabaseProvider);
  final scheduler = ref.watch(fsrsSchedulerProvider);

  return scheduler.buildDailyQueue(
    contentDb: contentDb,
    userDb: userDb,
    dailyNewLimit: settings.dailyNewCardsLimit,
  );
});

/// Reactive notifier managing the learner's active practice preset and configuration.
class ActivePresetNotifier extends StateNotifier<PracticePreset> {
  final UserDatabase _userDb;

  ActivePresetNotifier(this._userDb)
      : super(PracticePreset.getById(_userDb.loadActivePresetId()));

  void selectPreset(PracticePreset preset) {
    state = preset;
    _userDb.saveActivePresetId(preset.id);
  }

  void selectPresetById(String id) {
    final preset = PracticePreset.getById(id);
    selectPreset(preset);
  }

  void updateConfiguration(PracticeConfiguration config) {
    state = PracticePreset(
      id: state.id,
      name: state.name,
      description: state.description,
      configuration: config,
    );
  }
}

/// Exposes the currently active preset (persisted across launches in SQLite).
final activePresetProvider =
    StateNotifierProvider<ActivePresetNotifier, PracticePreset>((ref) {
  final userDb = ref.watch(userDatabaseProvider);
  return ActivePresetNotifier(userDb);
});

/// Exposes the active practice configuration derived from [activePresetProvider].
final activeConfigurationProvider = Provider<PracticeConfiguration>((ref) {
  return ref.watch(activePresetProvider).configuration;
});
