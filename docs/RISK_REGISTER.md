# Tsuzuri — Technical Risk Register & Mitigation Strategy

**Document Reference**: `RISK_REGISTER.md`  
**Application**: Tsuzuri (綴り)  
**Target Specification**: Practice & Learning System Functional Specification v1.0  
**Date**: November 2026  
**Auditor**: Antigravity Technical Architecture Team  

---

## 1. Risk Evaluation Matrix & Scoring Criteria

Risks are evaluated using a standard 5×5 probability and impact framework:
- **Likelihood**: 1 (Rare), 2 (Unlikely), 3 (Moderate), 4 (Likely), 5 (Almost Certain)
- **Impact**: 1 (Negligible), 2 (Minor), 3 (Moderate), 4 (Major), 5 (Catastrophic)
- **Severity Score**: $\text{Likelihood} \times \text{Impact}$
  - **1–6**: Low
  - **8–12**: Medium
  - **15–20**: High
  - **25**: Critical

---

## 2. Detailed Technical Risk Register

| Risk ID | Risk Description | Likelihood | Impact | Severity | Primary Mitigation |
|---|---|:---:|:---:|:---:|---|
| **RSK-01** | Breaking the existing Writing module during refactoring | 2 | 5 | **Medium (10)** | Lock in comprehensive widget & integration baseline tests before touching `practice_screen.dart`. Wrap rather than rewrite `KanjiWritingCanvas`. |
| **RSK-02** | Duplicating handwriting evaluation logic for copy/guided modes | 2 | 4 | **Medium (8)** | Enforce single evaluation pipeline: pass flags (`copyMode`, `guidedMode`) into existing `KanjiWritingCanvas` and call the exact same `StrokeMatcher.validateStroke()`. |
| **RSK-03** | Introducing over-engineered architectural complexity | 3 | 3 | **Medium (9)** | Reject heavy frameworks. Use lightweight sealed classes for prompts/answers, keeping the Exercise Engine under 250 lines of pure Dart. |
| **RSK-04** | Audio playback lifecycle bugs (autoplay loops on widget rebuild) | 4 | 3 | **Medium (12)** | Guard audio autoplay with an exercise-scoped token in `ExerciseController`. Never call speech synthesis directly inside Flutter widget `build()` methods. |
| **RSK-05** | Ambiguous Kanji readings in audio exercises | 4 | 3 | **Medium (12)** | Never generate audio from isolated kanji readings. Map explicit vocabulary words or contextual compound examples in `kanji_content.db`. |
| **RSK-06** | Incorrect progress updates (copy/guided practice counting as recall) | 3 | 4 | **Medium (12)** | Strictly gate FSRS updates by `ExerciseType.isFreeRecall`. Divert copy and guided practice completion directly to `writing_metrics`. |
| **RSK-07** | FSRS card duplication or orphaned cards across modes | 2 | 4 | **Medium (8)** | Use SQLite unique compound primary key `(codepoint, skill_type)`. Enforce domain enum mapping so configuration toggles cannot create new cards. |
| **RSK-08** | Database migration failures corrupting user progress | 2 | 5 | **Medium (10)** | Enforce atomic SQLite transactions (`BEGIN TRANSACTION; ... COMMIT;`) during Schema v3 migration with pre-migration automated backup. |
| **RSK-09** | Offline compatibility failures due to missing device Japanese TTS | 4 | 3 | **Medium (12)** | Perform startup Japanese voice availability check. If unavailable, display guidance banner and gracefully disable audio exercises without crashing. |
| **RSK-10** | Content and stroke-data inconsistencies between KANJIDIC2 & KanjiVG | 1 | 4 | **Low (4)** | Automated Python CI verification script (`tools/test_content_db.py`) validates stroke count synchronization and non-null geometry for all 2,136 kanji. |

---

## 3. Deep-Dive Analysis for Critical & High Severity Risks

### RSK-01: Breaking Existing Writing Module
- **Trigger**: Modifying `PracticeScreen` to accommodate multiple exercise types breaks touch coordinates, canvas resizing, or completion callbacks.
- **Root Cause**: Tight coupling of state management and gesture capture in `_PracticeScreenState`.
- **Detection Strategy**: Automated widget tests in `test/writing_flow_regression_test.dart` simulating pointer down/move/up events on the canvas.
- **Preventive Mitigation**: Keep `KanjiWritingCanvas` as an independent, encapsulated widget. The `ExerciseEngine` simply provides it with `expectedStrokes` and `leniency`.
- **Rollback Plan**: Revert `PracticeScreen` git commit; the canvas and stroke matcher remain untouched in separate files.

### RSK-04: Audio Playback Lifecycle Loops
- **Trigger**: User rotates device, switches system dark/light theme, or triggers an error banner, causing Flutter to call `build()` repeatedly.
- **Root Cause**: Placing `speechService.speak()` inside widget build methods or reactive Riverpod listeners without state flags.
- **Detection Strategy**: Lifecycle test verifying that widget rebuilds with identical `exerciseId` do not call `ISpeechService.speak()` more than once.
- **Preventive Mitigation**: Audio autoplay must be managed by an `AsyncNotifier` state machine:
  ```dart
  if (state.hasPlayedAudioFor(exercise.exerciseId)) return;
  state.markAudioPlayed(exercise.exerciseId);
  speechService.speak(exercise.audioText);
  ```
- **Rollback Plan**: Add a manual "Play Audio" tap requirement until autoplay state debouncing is stabilized.

### RSK-06: Copy & Guided Practice Polluting FSRS Recall Stability
- **Trigger**: User uses *Copy Kanji* or *Guided Practice* to learn a difficult character, and the system records an "Easy" or "Good" FSRS review.
- **Root Cause**: Hardcoded call to `FsrsSchedulerService.recordPracticeCompletion()` inside generic canvas completion handlers.
- **Detection Strategy**: Unit tests asserting that completing an exercise where `isFreeRecall == false` leaves `srs_cards` completely unchanged.
- **Preventive Mitigation**:
  ```dart
  void handleExerciseCompleted(ExerciseDefinition exercise, int mistakes, int hints) {
    if (exercise.exerciseType.isFreeRecall) {
      fsrsScheduler.recordPracticeCompletion(..., skillType: exercise.exerciseType.skillType);
    } else {
      userDb.insertWritingMetric(..., exerciseType: exercise.exerciseType);
    }
  }
  ```
- **Rollback Plan**: Clear incorrect cards with database query: `DELETE FROM srs_cards WHERE skill_type = 'writing_diagnostic'`.

### RSK-08: Database Migration Failures
- **Trigger**: App update from `v1.2.2` to a version with Schema v3 encounters an SQLite lock or syntax error mid-migration.
- **Root Cause**: Non-atomic schema alteration without rollback guard.
- **Detection Strategy**: Test suite running migration on simulated Schema v1 and v2 test databases in `test/db_and_fsrs_test.dart`.
- **Preventive Mitigation**:
  - Always execute migrations inside an explicit `BEGIN TRANSACTION;` and `COMMIT;`.
  - In `catch (e)`, call `_db.execute('ROLLBACK;')`.
  - Automatically dump a safety snapshot `user_progress.db.bak` before executing migration commands.
- **Rollback Plan**: Restore `user_progress.db` from `user_progress.db.bak`.

### RSK-09: Offline Japanese TTS Voice Absence
- **Trigger**: User installs Tsuzuri on an Android phone whose OEM ROM (e.g. some budget devices or custom ROMs) does not have Japanese voice data pre-installed.
- **Root Cause**: Calling `flutter_tts.speak()` with `'ja-JP'` throws a platform exception or speaks with a garbled English fallback voice.
- **Detection Strategy**: Startup query: `await flutterTts.getLanguages()` checking for `'ja'` or `'ja-JP'`.
- **Preventive Mitigation**:
  - If Japanese voice is absent, set `isJapaneseAvailable = false`.
  - In the UI, show a setup banner: *"Japanese voice data is required for audio exercises. Tap here to install it in Android Settings."*
  - Automatically hide or disable *Audio $\rightarrow$ Write* and *Audio $\rightarrow$ Recognition* so users can continue practicing with Writing and Recognition without errors.
- **Rollback Plan**: Audio exercises remain disabled until system voice files are verified.
