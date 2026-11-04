# Tsuzuri — Milestone 0: Test Coverage Matrix

**Document Reference**: `M0_TEST_COVERAGE_MATRIX.md`  
**Application**: Tsuzuri (綴り)  
**Milestone**: Milestone 0 (Stabilization & Test Lock)  
**Date**: November 2026  
**Status**: 15 / 15 Tests Passing  

---

| Behavior Category | Specific Target Behavior | Existing Test? | New Test? | Verified? | Verification File & Notes |
|---|---|:---:|:---:|:---:|---|
| **Curve Distance** | Iterative discrete Fréchet distance equals 0 for identical curves | Yes | No | **YES** | `test/stroke_matcher_test.dart`: `DiscreteFrechet.compute` |
| **Stroke Tolerance** | Accepts noisy curve with sensor jitter, 0.9x scale, and wobble | Yes | No | **YES** | `test/stroke_matcher_test.dart`: Synthesizes noisy variant of stroke 0 of 十 |
| **Direction Check** | Rejects reversed stroke direction as `wrongDirection` | Yes | No | **YES** | `test/stroke_matcher_test.dart`: Reverses horizontal stroke points |
| **Order Check (Unit)** | Detects stroke order violation (drawing stroke 2 before stroke 1) | Yes | No | **YES** | `test/stroke_matcher_test.dart`: `matchedLaterStrokeIndex == 1` |
| **Tap Rejection** | Rejects accidental tap under 10px arc length as `tooShort` | Yes | No | **YES** | `test/stroke_matcher_test.dart`: 2-point micro-tap rejected |
| **Length Gate** | Rejects stroke shorter than 50% of reference length | Yes | No | **YES** | `test/stroke_matcher_test.dart`: Short line rejected as `badShape` |
| **Content Retrieval** | Loads kanji by codepoint and unpacks 50-point vector BLOB | Yes | No | **YES** | `test/db_and_fsrs_test.dart`: Tests U+65E5 (日) stroke unpack |
| **Grade Derivation** | Maps mistakes and hints used to FSRS ratings (Easy, Good, Hard, Again) | Yes | No | **YES** | `test/db_and_fsrs_test.dart`: Tests `FsrsSchedulerService.deriveGrade` |
| **DB Isolation** | Writable `UserDatabase` stores card progress without affecting content DB | Yes | No | **YES** | `test/db_and_fsrs_test.dart`: In-memory isolated DB tested |
| **Backup & Restore** | JSON snapshot export and restore survives app reinstallation | Yes | No | **YES** | `test/db_and_fsrs_test.dart`: Exports and restores into clean instance |
| **Daily Queue** | Orders due review cards first, then unstudied kanji up to daily limit | Yes | No | **YES** | `test/db_and_fsrs_test.dart`: Due card 山 prioritized before new cards |
| **UI Prompt Rendering** | Meaning prompt card renders English meanings, readings, and stroke count | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 1 verifies prompt elements |
| **Canvas Button States** | `Undo Stroke` button is disabled at stroke 0 and enables after stroke 1 | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 1 & 2 verify button states |
| **Touch Gesture Scaling** | Dispatches pointer down/move/up across screen and normalizes to 109×109 space | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 2 simulates screen coordinates |
| **Multi-Stroke Progression** | Drawing stroke 0 advances index to `Stroke 1 / 2`; drawing stroke 1 completes character | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 2 executes full 十 completion |
| **FSRS Card Creation** | Completing kanji creates card in `srs_cards` (`reps=1`, `state=2`, `lastReview`) | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 2 verifies DB row creation |
| **Review Log Storage** | Completing kanji inserts record in `review_logs` with rating, mistakes, and hints | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 2 verifies review log row |
| **Order Error Feedback** | Drawing stroke 1 before stroke 0 displays `"Wrong stroke order"` red banner | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 3 verifies feedback banner |
| **Grade Adaptation** | Making 1 mistake on stroke order downgrades completion grade from `Easy` to `Good` | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 3 verifies grade adaptation |
| **Undo Interaction** | Tapping `Undo Stroke` reverts last verified stroke and clears banner | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 4 tests undo stroke |
| **Restart Interaction** | Tapping `Restart` resets canvas back to stroke 0 and clears all mistakes | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 4 tests restart canvas |
| **Queue Advancement** | Completing first kanji in queue enables `"Next Kanji"` button and advances to second kanji | No | **Yes** | **YES** | `test/writing_flow_regression_test.dart`: Test 5 completes multi-kanji session |
| **Audio / TTS** | Playback on question load and manual replay | No | No | **N/A** | *Not implemented in baseline (Scheduled for M2)* |
| **Copy Practice** | Static reference character display on canvas | No | No | **N/A** | *Not implemented in baseline (Scheduled for M3)* |
| **Guided Writing** | Step-by-step locked stroke sequence with animation overlay | No | No | **N/A** | *Not implemented in baseline (Scheduled for M3)* |
| **Recognition 4-Choice** | Multiple-choice meaning, reading, and tile evaluation | No | No | **N/A** | *Not implemented in baseline (Scheduled for M6)* |
| **Skill-Specific FSRS** | Separate FSRS cards for meaning, reading, listening, writing | No | No | **N/A** | *Not implemented in baseline (Scheduled for M5)* |
