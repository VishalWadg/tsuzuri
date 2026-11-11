# Milestone 7: UI Exposure, Persistence Hydration & End-to-End Modular Content Wiring

## Overview
While the backend contracts, priority registry, offline/online ingestion loaders, and security validators were implemented in `lib/src/content/`, learners initially had no UI controls or startup persistence connecting those capabilities to live app runs. Milestone 7 completes end-to-end runtime wiring across startup, database persistence, UI screens, exercise generation, and custom media playback.

---

## Architectural Decisions & Rationales

### 1. UserDatabase Schema v4 (`installed_sources`)
- **Decision**: Added an explicit relational `installed_sources` table (`UserDatabase.currentSchemaVersion = 4`) storing `source_id`, `name`, `version`, `origin_type`, `origin_uri`, `package_dir`, `capabilities_json`, `priority`, `enabled`, and `installed_at`.
- **Rationale**: Imported packages staged on disk (`packages/<id>/`) must survive app restarts alongside their custom priority ordering and enabled toggles. `installed_sources` is also included cleanly in `exportBackupJson()` / `importBackupJson()` while staying decoupled from immutable `srs_cards` and `review_logs`.

### 2. Startup Hydration via `UncontrolledProviderScope`
- **Decision**: Initialized a `ProviderContainer` in [`lib/main.dart`](file:///d:/offline_kanji_practice_v1/lib/main.dart) overriding `contentDatabaseProvider`, `userDatabaseProvider`, and `appDocumentsDirectoryProvider`, awaited `ContentSourceManager.hydrateOnStartup()`, and launched the app inside `UncontrolledProviderScope`.
- **Rationale**: Ensures persisted custom metadata, stroke, and audio sources are validated and mounted into `ContentSourceRegistry` before Frame 0 renders, eliminating UI flicker or incomplete initial study queues.

### 3. Batch Read Optimization in `ContentRepository.getAllKanjiOrdered()`
- **Decision**: Preload `BundledMetadataSource.contentDb.getAllKanjiOrdered()` in a single SQLite batch query and layer active custom source overrides per codepoint rather than running sequential per-kanji async SQLite queries.
- **Rationale**: Sequential per-character queries across 2,136 Joyo Kanji previously executed 4,000+ individual SQLite calls and `await` hops. Batching reduces full deck resolution to a single query (~5ms) while preserving priority override and fallback guarantees.

### 4. Custom Audio File / URL Playback with Seamless TTS Fallback
- **Decision**: Introduced [`IAudioPlaybackService`](file:///d:/offline_kanji_practice_v1/lib/src/services/audio_playback_service.dart) (`AudioplayersPlaybackService` backed by `audioplayers`, lazily instantiating `AudioPlayer` on first media call) and extended [`AudioPrompt`](file:///d:/offline_kanji_practice_v1/lib/src/domain/exercises/exercise_prompt.dart) with optional `AudioPronunciation?`.
- **Rationale**: Lazy player construction prevents `MissingPluginException` in headless widget tests that don't invoke media playback. When custom `localFile`, `remoteUrl`, or `asset` audio is active, `AudioPromptCard` hides the OS `ja-JP` TTS missing warning and falls back gracefully to `ISpeechService` if media playback fails.

### 5. Metadata-Only Kanji Guard in Writing Sessions
- **Decision**: Filtered `kanji.strokes.isEmpty` cleanly in `ExerciseEngine.createSessionQueue` / `createSessionQueueAsync` for `ExerciseActivity.writing` and guarded single-tile taps on [`HomeScreen`](file:///d:/offline_kanji_practice_v1/lib/src/ui/screens/home_screen.dart).
- **Rationale**: Because `HandwritingAnswerMethod` enforces non-empty reference strokes, metadata-only custom expansion packs can be studied in Recognition modes without risking crashes in Writing queues.

### 6. Stateful URL Dialog & Material 3 Source Manager UI
- **Decision**: Built [`ContentSourcesScreen`](file:///d:/offline_kanji_practice_v1/lib/src/ui/screens/content_sources_screen.dart) accessible from both [`SettingsScreen`](file:///d:/offline_kanji_practice_v1/lib/src/ui/screens/settings_screen.dart) and [`HomeScreen`](file:///d:/offline_kanji_practice_v1/lib/src/ui/screens/home_screen.dart), isolating the remote URL text field inside a stateful `_ConnectOnlineSourceDialog`.
- **Rationale**: Isolating `TextEditingController` inside the dialog's own `State.dispose()` guarantees it is only disposed after the route closing animation completes, preventing `TextEditingController was used after being disposed` exceptions. Added `android.permission.INTERNET` to `AndroidManifest.xml` so online source fetching works in release builds.

---

## Verification Summary
- Added [`test/content/source_manager_and_persistence_test.dart`](file:///d:/offline_kanji_practice_v1/test/content/source_manager_and_persistence_test.dart) (5 tests covering Schema v4, restart hydration, priority swapping, online updates, and writing-mode filtering).
- Added [`test/content/content_sources_ui_test.dart`](file:///d:/offline_kanji_practice_v1/test/content/content_sources_ui_test.dart) (4 widget integration tests covering Settings navigation, remote HTTP import -> Home Deck expansion -> toggle/delete, error dialog display, and custom `AudioPromptCard` playback + TTS fallback).
- Full test suite: **391/391 passing**; `flutter analyze`: **0 issues found**.
