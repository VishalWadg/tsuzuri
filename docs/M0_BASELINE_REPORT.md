# Tsuzuri — Milestone 0: Baseline Stabilization & Test Lock Report

**Document Reference**: `M0_BASELINE_REPORT.md`  
**Application**: Tsuzuri (綴り) — Offline-first Japanese Kanji Learning Application  
**Milestone**: Milestone 0 (Stabilization & Test Lock)  
**Status**: Completed & Verified  
**Date**: November 2026  
**Auditor / Engineer**: Antigravity Senior Flutter Engineering Team  

---

## 1. Toolchain & Environment Specifications

The baseline environment was verified directly on the host development machine:

| Component | Version / Revision | Notes |
|---|---|---|
| **Flutter SDK** | `3.47.9` (Channel `stable`) | Framework revision `c197ca5199` |
| **Dart SDK** | `3.13.7` | Bundled with Flutter 3.47.9 |
| **DevTools** | `2.60.0` | |
| **Host OS** | Windows (PowerShell Shell) | Target: Android / Cross-platform |
| **flutter_riverpod** | `^2.6.1` (Active: `2.6.1`) | Dependency injection & reactive state |
| **sqlite3 / sqlite3_flutter_libs** | `^2.5.0` / `^0.5.28` (Active: `2.9.4` / `0.5.42`) | Direct SQLite driver bindings |
| **fsrs** | `^2.0.1` (Active: `2.0.1`) | Free Spaced Repetition Scheduler v2 |
| **share_plus** | `^12.0.2` (Active: `12.0.2`) | Database backup sharing |
| **file_picker** | `^11.0.3` (Active: `11.0.3`) | Backup file restore |

---

## 2. Initial vs. Final Quality Baseline

### 2.1 Initial Baseline (Pre-M0)
- **`flutter test` Execution**:
  - **Exit Code**: `0`
  - **Total Tests Run**: 10
  - **Passed**: 10
  - **Failed**: 0
  - **Skipped**: 0
  - **Execution Time**: ~0.8s
  - **Suites**:
    - `test/stroke_matcher_test.dart` (6 unit tests)
    - `test/db_and_fsrs_test.dart` (4 unit tests)
- **`flutter analyze` Execution**:
  - **Exit Code**: `0`
  - **Issues Found**: `0` (clean analysis)

### 2.2 Final Baseline (Post-M0 Test Lock)
- **`flutter test` Execution**:
  - **Exit Code**: `0`
  - **Total Tests Run**: **15** (+5 new widget integration tests)
  - **Passed**: **15**
  - **Failed**: 0
  - **Skipped**: 0
  - **Execution Time**: ~1.7s
  - **Suites**:
    - `test/stroke_matcher_test.dart` (6 tests)
    - `test/db_and_fsrs_test.dart` (4 tests)
    - `test/writing_flow_regression_test.dart` (5 tests)
- **`flutter analyze` Execution**:
  - **Exit Code**: `0`
  - **Issues Found**: `0` (clean analysis in 5.7s)

---

## 3. Existing Test Coverage Assessment

A line-by-line inspection of the 10 pre-existing tests revealed strong low-level mathematical and database coverage, but a **total absence of UI and interaction tests**:

| Test Suite | File | What It Genuinely Covered | What Was Missing / Weak |
|---|---|---|---|
| **Stroke Geometry & Fréchet Engine** | [`test/stroke_matcher_test.dart`](file:///d:/offline_kanji_practice_v1/test/stroke_matcher_test.dart) | • Identical curve zero distance.<br>• Synthesized noisy curve pass.<br>• Reversed curve rejection.<br>• Out-of-order stroke detection.<br>• Accidental tap rejection (<10px).<br>• Length-ratio gate (<50% ref). | Did not test multi-stroke sequential writing, canvas coordinate scaling, gesture handling, touch smoothing on live input, or UI feedback banner state. |
| **Dual DB & FSRS Scheduling** | [`test/db_and_fsrs_test.dart`](file:///d:/offline_kanji_practice_v1/test/db_and_fsrs_test.dart) | • Read-only content DB codepoint lookup.<br>• 50-point blob unpacking.<br>• Pure grade derivation (`deriveGrade`).<br>• Isolated user DB JSON backup & restore.<br>• Queue ordering (due cards before new). | Did not test `PracticeScreen` event firing, Riverpod provider invalidation (`progressRefreshTriggerProvider`), real-time completion card presentation, or button state mutations. |

---

## 4. Tracing the Meaning → Write Kanji Execution Flow

The end-to-end flow was traced through source code inspection:

1. **Queue Generation**: `dailyQueueProvider` in [`app_providers.dart`](file:///d:/offline_kanji_practice_v1/lib/src/providers/app_providers.dart#L66-L78) triggers `FsrsSchedulerService.buildDailyQueue()`. It queries `srs_cards` for due cards (`due_date <= now`), then appends unstudied kanji up to `dailyNewCardsLimit`.
2. **Screen Initialization**: `HomeScreen` pushes `PracticeScreen(queue: queue)`. `PracticeScreen` extracts `item = widget.queue[_currentIndex]`.
3. **Prompt Rendering**: The top card in [`practice_screen.dart`](file:///d:/offline_kanji_practice_v1/lib/src/ui/screens/practice_screen.dart#L85-L120) renders `kanji.meanings.join(', ')`, `kanji.strokeCount`, and formatted on'yomi/kun'yomi readings.
4. **Canvas Layout & Touch Tracking**: `KanjiWritingCanvas` renders a square `AspectRatio` wrapping a `Listener(onPointerDown, onPointerMove, onPointerUp, onPointerCancel)`. When the user draws, raw screen `Offset` points accumulate in `_activePoints`.
5. **Coordinate Normalization**: On pointer up, `StrokeGeometry.normalizeToKanjiSpace()` scales user touch coordinates from screen dimensions $(W \times H)$ into KanjiVG's canonical $109 \times 109$ coordinate space:
   $$\text{point}_{109} = \left(\text{point}_x \times \frac{109.0}{W},\; \text{point}_y \times \frac{109.0}{H}\right)$$
6. **Stroke Evaluation**: `StrokeMatcher.validateStroke()` applies a 1-pass moving average jitter filter, verifies length ratio $\ge 50\%$, computes start direction cosine, and calculates iterative discrete Fréchet distance.
7. **Tactile & Visual Feedback**:
   - **Pass**: Banner turns green (`Stroke N / Total`), `FeedbackService.notifySuccess()` fires 1 vibration pulse and a system click.
   - **Fail**: Banner turns red (e.g. `Wrong stroke order`), `FeedbackService.notifyFailure()` fires 2 vibration pulses and an alert sound.
8. **Character Completion**: When `_currentStrokeIndex == referenceStrokes.length`:
   - `FeedbackService.notifyCharacterCompleted()` fires.
   - `onCompleted(mistakes, hintsUsed)` callback invokes `FsrsSchedulerService.deriveGrade()`.
   - `FsrsSchedulerService.recordPracticeCompletion()` computes updated stability/interval via `fsrs_pkg.Scheduler.reviewCard()`.
   - `userDb.upsertCard()` writes to `srs_cards` and `userDb.insertReviewLog()` writes to `review_logs`.
   - The completion card appears with FSRS Grade and next review date.
9. **Queue Advancement**: Tapping `"Next Kanji"` increments `_currentIndex`, resets completion state, and presents the next character. On the final kanji, the button reads `"Finish Session"` and pops navigation.

---

## 5. New Meaning → Write Regression Test Suite

Created: [`test/writing_flow_regression_test.dart`](file:///d:/offline_kanji_practice_v1/test/writing_flow_regression_test.dart)

The new suite tests the complete integration flow under simulated real-world conditions:

1. **`1. Verifies Meaning Prompt card elements and initial canvas state`**:
   - Asserts English meanings, stroke counts, on'yomi/kun'yomi labels, and action buttons (`Hint`, `Undo Stroke`, `Restart`).
   - Asserts `Undo Stroke` button is disabled when stroke count is 0.
2. **`2. Executes complete Meaning → Write Kanji drawing flow, verifies completion & FSRS persistence`**:
   - Simulates drawing stroke 0 (horizontal line) and stroke 1 (vertical line) of Kanji「十」(U+5341).
   - Asserts sequential progression (`Stroke 1 / 2` banner, `Undo Stroke` enabled).
   - Asserts character completion card appears (`Completed「十」— FSRS Grade: Easy`).
   - Asserts FSRS card creation in `srs_cards` table (`reps = 1`, `state = 2 [review]`, `last_review != null`).
   - Asserts review log insertion in `review_logs`.
3. **`3. Rejects wrong stroke order, displays feedback banner, and adapts FSRS grade`**:
   - Draws stroke 1 (vertical) before stroke 0.
   - Asserts feedback banner displays `"Wrong stroke order"` and stroke count does not advance.
   - Completes the character with 1 mistake and asserts that the derived FSRS grade drops from `Easy` to `Good`.
4. **`4. Undo and Restart buttons reset stroke progression as expected`**:
   - Draws stroke 0, verifies `Undo Stroke` decrements index back to 0 and re-disables the button.
   - Draws stroke 0, verifies `Restart` resets the entire canvas state.
5. **`5. Advances through multi-kanji queue to Next Kanji`**:
   - Loads a multi-kanji queue (十 and 一).
   - Completes the first kanji, taps `"Next Kanji"`, verifies header advances to `(2 / 2)`, and completes the second kanji.

---

## 6. Fixes Made During Test Suite Stabilization

During the creation of the integration test, two technical friction points were identified and resolved in the test harness:

1. **Headless Test Viewport Clipping**:
   - *Problem*: In headless Flutter widget tests, the default virtual window is $800 \times 600$. Because `PracticeScreen` uses a `SingleChildScrollView` containing an `AppBar`, prompt card, and square aspect-ratio canvas, the canvas extended past 600 vertical pixels. Dispatched touch gestures were clipped by the viewport edge.
   - *Fix*: Configured standard mobile viewport dimensions in the test setup:
     ```dart
     tester.view.physicalSize = const Size(1080, 1920);
     tester.view.devicePixelRatio = 1.0;
     ```
2. **Native Platform Channel Mocking**:
   - *Problem*: In headless widget test environments, native Android method channel calls (`com.tsuzuri.kanji/feedback`) throw missing plugin errors unless intercepted.
   - *Fix*: Registered a test mock binary messenger handler returning `true` for all haptic calls:
     ```dart
     TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
         .setMockMethodCallHandler(const MethodChannel('com.tsuzuri.kanji/feedback'), (call) async => true);
     ```

---

## 7. Known Gaps & Limitations Remaining

While the writing practice flow is now locked with 100% passing tests, the following architectural gaps remain for subsequent milestones:
1. **Zero Audio / TTS Test Coverage**: Because TTS is not yet implemented, no audio playback tests exist.
2. **Recognition Flow Untested**: Recognition practice is not yet implemented.
3. **FSRS Granularity**: All writing tests still key cards by `(codepoint, 'writing')` because Schema v3 has not yet been introduced.
