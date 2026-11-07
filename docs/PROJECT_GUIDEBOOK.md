# Tsuzuri (綴り) — The Comprehensive Beginner-Friendly Architecture & Project Guidebook

Welcome to **Tsuzuri (綴り)**! This guide is written specifically for learners, junior developers, and engineering peers. It explains not just **what** the app does, but **how** every piece of code was architected, **why** specific technologies were chosen over alternatives, and **how you can explain and teach this system to others**.

---

## Table of Contents
1. [Chapter 1: What is Tsuzuri? (Mission & Philosophy)](#chapter-1-what-is-tsuzuri-mission--philosophy)
2. [Chapter 2: The Tech Stack & Why Each Tool Was Chosen](#chapter-2-the-tech-stack--why-each-tool-was-chosen)
3. [Chapter 3: Architectural Decisions Across Milestones 0 to 6](#chapter-3-architectural-decisions-across-milestones-0-to-6)
4. [Chapter 4: Algorithmic Deep Dives (Matching & Scheduling)](#chapter-4-algorithmic-deep-dives-matching--scheduling)
5. [Chapter 5: Codebase Tour & Reactive Data Flow](#chapter-5-codebase-tour--reactive-data-flow)
6. [Chapter 6: Troubleshooting & Real-World Lessons](#chapter-6-troubleshooting--real-world-lessons)
7. [Chapter 7: How to Explain Tsuzuri (Portfolio & Interview Guide)](#chapter-7-how-to-explain-tsuzuri-portfolio--interview-guide)

---

## Chapter 1: What is Tsuzuri? (Mission & Philosophy)

### 1.1 The Problem It Solves
To become literate in Japanese, learners must master at least **2,136 Joyo Kanji** (regular-use Chinese characters). Unlike alphabet-based languages, Kanji presents three steep hurdles:
1. **Logographic Complexity**: Characters range from 1 to 29+ intricate strokes.
2. **Stroke Order & Direction Invariants**: In Japanese orthography, stroke order and direction are not decorative—they determine character balance, cursive readability, and radical structure.
3. **Multi-Faceted Memory (Split Modalities)**: A student might easily recognize what a kanji means when reading a sentence, but completely blank out when asked to draw it on paper or identify its spoken sound.

### 1.2 Core Architectural Principles

```
┌────────────────────────────────────────────────────────┐
│            Tsuzuri Architectural Pillars               │
├──────────────────┬──────────────────┬──────────────────┤
│  100% Offline    │  Zero-Account    │   Multi-Skill    │
│  No network or   │  No sign-in or   │  Writing memory  │
│  servers needed  │  cloud tracking  │  ≠ Reading memory│
└──────────────────┴──────────────────┴──────────────────┘
```

1. **100% Offline-First Guarantee**: 
   The application runs anywhere—in airplane mode, on underground subway commutes, or in areas without cellular reception. There are zero remote servers, no analytics beacons, and no cloud logins.
2. **Zero-Account Privacy**: 
   All spaced-repetition schedules, review logs, and personal settings live in an on-device SQLite database that belongs entirely to the learner.
3. **Multi-Skill FSRS Isolation**: 
   Writing a Kanji from memory is fundamentally harder than recognizing it in a 4-choice quiz. Tsuzuri separates the memory models for each skill so assisted practice never pollutes true recall mastery.

---

## Chapter 2: The Tech Stack & Why Each Tool Was Chosen

Beginners often ask: *"Why didn't you just use React Native, Firebase, or a pre-made machine learning model?"* Here is the technical rationale behind every choice:

### 2.1 Framework: Flutter & Dart
- **What it is**: Google's open-source UI toolkit compiled directly to native machine code (ARM/x86).
- **Why we chose it**:
  - **High-Frame-Rate Canvas Rendering**: Drawing kanji requires capturing touch points at 60Hz or 120Hz with zero input lag. Flutter's `CustomPainter` talks directly to the Skia/Impeller graphics engine, providing low-latency stylus and finger tracking.
  - **Single Portable Codebase**: Runs on Android, iOS, Windows, macOS, and Linux from one shared Dart codebase.
  - **AOT (Ahead-of-Time) Compilation**: No JavaScript bridge overhead (unlike React Native), ensuring smooth handwriting animations and instant app launch.

### 2.2 State Management: Flutter Riverpod 2.x
- **What it is**: A reactive, compile-time-safe caching and dependency injection framework for Dart.
- **Why we chose it over Provider or Bloc**:
  - **No `BuildContext` Dependency**: Services and database queries can be read and watched outside the widget tree.
  - **Compile-Time Safety**: Eliminates `ProviderNotFoundException` at runtime.
  - **Effortless Test Overrides**: During automated tests, we can replace real database providers or speech engines with mocks in one line:
    ```dart
    final container = ProviderContainer(
      overrides: [speechServiceProvider.overrideWithValue(fakeSpeechService)],
    );
    ```

### 2.3 Persistence: Dual SQLite Architecture (`sqlite3` / `drift`)
- **What it is**: Two dedicated on-device relational database files.
- **Why we chose it over SharedPreferences, Hive, or Firebase**:
  - **ACID Transactions**: Relational integrity ensures progress is never corrupted if the phone battery dies mid-stroke.
  - **Separation of Concerns**: Storing immutable dictionary data separately from mutable user reviews (see Chapter 3).

### 2.4 Stroke Matching: Discrete Fréchet Distance (Math over ML)
- **What it is**: A mathematical curve-similarity metric that measures the minimum leash length required to walk a person and a dog along two respective curves without either walking backwards.
- **Why we chose it over Machine Learning (Neural Networks / CNNs)**:
  - **100% Deterministic**: Machine learning models can produce unpredictable "hallucinations" or false positives on noisy inputs. Fréchet distance yields exact geometric similarity.
  - **Instant Execution**: Runs in sub-millisecond time ($O(N^2)$ with $N=50$ points) on any low-end smartphone CPU without needing TensorFlow Lite models or GPU acceleration.
  - **Direction-Sensitive**: A reverse stroke from right-to-left will fail even if the drawn pixels look identical to an untrained image classifier.

### 2.5 Spaced Repetition: Modern FSRS (Free Spaced Repetition Scheduler)
- **What it is**: A 21st-century spaced-repetition algorithm based on the DSR model (Difficulty, Stability, Retrievability) developed by Jarrett Ye.
- **Why we chose it over SM-2 (Anki's default)**:
  - **Accurate Memory Decay**: SM-2 (from 1987) uses heuristic multipliers that cause "ease hell" when cards are failed. FSRS calculates exact probability of recall ($R = (1 + factor \cdot t / S)^{-1}$) based on cognitive memory research.

### 2.6 Audio Synthesis: Operating System Text-To-Speech (`flutter_tts`)
- **What it is**: A bridge to native platform speech engines (Google Speech Services on Android, SAPI/OneCore on Windows, AVFoundation on iOS).
- **Why we chose it over Bundled MP3s**:
  - Bundling audio files for 2,136+ Joyo kanji (with multiple readings each) would require 6,000+ `.mp3` files, expanding the app download from **~25 MB to over 300 MB**. Native TTS delivers zero-byte app bundle impact.

---

## Chapter 3: Architectural Decisions Across Milestones 0 to 6

The project evolved through 7 disciplined milestones. Here is the architectural reasoning behind each:

```mermaid
flowchart LR
    M0["M0: Test Baseline"] --> M1["M1: Exercise Abstraction"]
    M1 --> M2["M2: Audio & TTS"]
    M2 --> M3["M3: Advanced Writing"]
    M3 --> M4["M4: Practice Presets"]
    M4 --> M5["M5: Recognition & FSRS v3"]
    M5 --> M6["M6: Polish & Verification"]
```

### Milestone 0: Baseline Stabilization & Golden Test Lock
- **Decision**: Before refactoring anything, write comprehensive integration tests covering the existing free-writing flow.
- **Why**: Prevent regressions. These 5 golden tests (`test/writing_flow_regression_test.dart`) guaranteed that future additions would never break the fundamental stroke-matching and grading pipeline.

### Milestone 1: Reusable Exercise Domain Model
- **Decision**: Decompose monolithic practice screens into two abstract primitives:
  1. `ExercisePrompt`: What is presented to the learner (`MeaningPrompt`, `AudioPrompt`, `KanjiPrompt`).
  2. `ExerciseAnswerMethod`: How the learner responds (`HandwritingAnswerMethod`, `MultipleChoiceAnswerMethod`).
- **Why**: Decoupling the prompt from the answer method allowed us to create any exercise permutation (e.g. *Audio &rarr; Write Kanji*, *Kanji &rarr; Pick Meaning*, *Audio &rarr; Pick Meaning*) without duplicating UI or engine logic.

### Milestone 2: Audio Support & Native TTS Integration
- **Decision**: Wrap `flutter_tts` inside an abstract interface `ISpeechService`, coupled with an autoplay guard and a voice-availability check.
- **Why**: Flutter widget trees rebuild frequently. Without an explicit `_lastAutoplayedExerciseId` guard, audio would re-trigger repeatedly during screen rotations or state changes.

### Milestone 3: Advanced Writing Variations & FSRS Isolation
- **Decision**: Introduce three distinct writing variations:
  - **Stroke Guide Mode**: Restricts writing to the exact expected stroke, preventing learners from practicing mistakes.
  - **Watermark Copy Practice**: Renders faint reference stroke outlines directly on the canvas for beginners.
  - **Challenge Mode**: Strict geometric leniency, disabled animated hints.
- **Critical FSRS Rule**: Only **unassisted free-recall writing** updates the FSRS spaced-repetition card. Practicing with a watermark or stroke guide counts toward stroke metrics, but does not advance long-term retention stability.

### Milestone 4: Practice Presets & Learner Configurations
- **Decision**: Introduce `PracticePreset` and `PracticeConfiguration` data classes, surfaced through an interactive `PresetSelectorWidget` on the Home Screen.
- **Why**: Instead of forcing users to configure 10 separate toggles in settings, curated presets ("Beginner", "Challenge", "Audio Immersion", "Copy Practice") allow single-tap mode switching.

### Milestone 5: Recognition Modules & Multi-Skill Database Schema v3
- **Decision**: Expand the application beyond handwriting into **4-Choice Recognition** (Kanji &rarr; Meaning, Kanji &rarr; Reading, Audio &rarr; Meaning) with Schema v3 database migration.
- **Why**: Learning Japanese involves separate neural pathways: *grapheme-to-meaning* (recognition) and *memory-to-motor* (writing). Storing separate cards in SQLite under `(codepoint, skill)` ensures that being great at multiple-choice quizzes doesn't falsely convince the scheduler that you can write the kanji from memory.

### Milestone 6: Final Polish, Global Settings, & 88/88 Test Lock
- **Decision**: Introduce an Activity Segmented Control (`Writing` vs `Recognition`), global TTS speed and autoplay switches, full JSON backup/restore for all v3 metrics, and author a comprehensive verification test suite.
- **Why**: Unifies all modes into a cohesive production-ready interface with 100% automated test coverage (88/88 tests passing).

### Beyond Milestone 6: Plug-and-Play Modular Content Source System (Anki-Style Modularity)
- **Decision**: Decouple the monolithic content database into three orthogonal contracts (`IKanjiMetadataSource`, `IKanjiStrokeSource`, and `IKanjiAudioSource`), managed by a priority-based `ContentSourceRegistry` and unified `ContentRepository` facade.
- **Why**: 
  - Learners can now bring their own Kanji datasets, custom stroke styles, and pre-recorded audio packs without modifying source code.
  - Supports both **Offline ZIP Packages** and **Online Remote HTTP Sources** with automatic local disk caching.
  - **Graceful Fallback**: If a custom source only provides 10 JLPT N1 characters or lacks audio, the system automatically falls back to bundled defaults for everything else.
  - **FSRS Progress Invariance**: All user learning cards in `user_progress.db` remain permanently keyed by standard Unicode codepoints (`codepoint`). Adding, updating, or deactivating a custom source never corrupts or deletes user study history.
  - **Security & Integrity**: Integrated `ZipSlipGuard` prevents path traversal attacks, while `SourceValidator` checks SHA-256 hashes and JSON/SQLite integrity before mounting packages.

---

## Chapter 4: Algorithmic Deep Dives (Matching & Scheduling)

### 4.1 The 5-Stage Stroke Verification Pipeline
When a user draws a stroke on the screen, raw touch events produce a polyline of $(x, y)$ coordinates. How does Tsuzuri know if the stroke was drawn correctly?

```mermaid
flowchart TD
    Raw["Raw User Points (Canvas Coordinates)"] --> Norm["1. Coordinate Normalization (109x109 Space)"]
    Norm --> ArcLen["2. Equidistant Arc-Length Resampling (50 Points)"]
    ArcLen --> Gate1{"Gate 1: Minimum Length?"}
    Gate1 -- Too short --> Rej1["Reject: Tap Accidental"]
    Gate1 -- OK --> Gate2{"Gate 2: Length Ratio (50%-200%)?"}
    Gate2 -- Bad ratio --> Rej2["Reject: Stroke Too Short/Long"]
    Gate2 -- OK --> Gate3{"Gate 3: Start Chord Direction?"}
    Gate3 -- Inverted angle --> Rej3["Reject: Wrong Direction"]
    Gate3 -- OK --> Frechet["Compute Discrete Fréchet Distance"]
    Frechet --> Gate4{"Distance <= Dynamic Threshold?"}
    Gate4 -- Match --> Success["Accept: Snap to Reference SVG"]
    Gate4 -- Fail --> CheckOrder{"Matches Later Stroke in Character?"}
    CheckOrder -- Yes --> WrongOrder["Reject: Wrong Stroke Order"]
    CheckOrder -- No --> WrongShape["Reject: Incorrect Shape"]
```

#### Step-by-Step Breakdown:
1. **Coordinate Normalization**: Translates dynamic device pixels into KanjiVG's canonical $109 \times 109$ coordinate space.
2. **Equidistant Arc-Length Resampling**: Real humans draw fast or slow, producing uneven point clusters. Resampling places exactly 50 points at equal distances along the curve.
3. **The Length-Ratio Gate**: Immediately rejects strokes that are under 50% or over 200% of the reference stroke length.
4. **The Directional Chord Gate**: Evaluates the vector between point 0 and point 12 (first 25% of the stroke). If drawn backwards (e.g. bottom-to-top instead of top-to-bottom), it is rejected instantly before computing distance matrices.
5. **Discrete Fréchet Distance**: Compares the 50 user points against the 50 reference points. An iterative $O(N^2)$ algorithm with a 2-row rolling buffer checks both the raw position and a bounding-box-aligned variant.

---

### 4.2 Spaced Repetition: FSRS Mechanics Simplified
Spaced repetition is the science of reviewing an item right before you are about to forget it.

$$R(t) = \left(1 + \text{factor} \cdot \frac{t}{S}\right)^{-1}$$

- **Stability ($S$)**: The number of days it takes for retention probability ($R$) to drop from 100% to 90%. If a kanji has a stability of 30, you will remember it with 90% confidence in 30 days.
- **Difficulty ($D$)**: How inherently difficult the character is for you (from 1 to 10).
- **The Rating**:
  - `Easy`: Flawless recall, stroke snapped on first attempt &rarr; Stability increases significantly.
  - `Good`: Correct recall with minor hesitation &rarr; Normal stability growth.
  - `Hard`: Recalled after multiple attempts &rarr; Mild stability growth.
  - `Again`: Failed or requested hints &rarr; Stability drops, scheduled for review again today.

---

## Chapter 5: Codebase Tour & Reactive Data Flow

### 5.1 Directory Layout
```
lib/
├── main.dart                          # App entry point & database initialization
└── src/
    ├── data/                          # Persistence & SQLite
    │   ├── content_db.dart            # Read-only dictionary & stroke database
    │   ├── models.dart                # Immutable domain models (KanjiCharacter, UserCard)
    │   └── user_db.dart               # Writable user progress, reviews, settings
    ├── domain/exercises/              # Universal exercise abstraction
    │   ├── exercise_definition.dart   # Exercise model (prompt + answer method)
    │   ├── exercise_prompt.dart       # Sealed prompts (Meaning, Audio, Kanji)
    │   ├── exercise_answer_method.dart# Sealed answers (Handwriting, MultipleChoice)
    │   ├── exercise_result.dart       # Verification result & FSRS rating
    │   ├── exercise_types.dart        # Enums (SkillType, ExerciseActivity, etc.)
    │   └── practice_configuration.dart# Presets & custom session configs
213.     ├── matching/                      # Pure Dart stroke-matching algorithms
214.     │   ├── frechet.dart               # Discrete Fréchet distance engine
215.     │   ├── point2d.dart               # 2D vector geometry & arc-length resampling
216.     │   └── stroke_matcher.dart        # 5-stage verification & leniency gates
217.     ├── content/                       # Plug-and-play modular source architecture
218.     │   ├── contracts/                 # IKanjiMetadataSource, IKanjiStrokeSource, IKanjiAudioSource
219.     │   ├── registry/                  # ContentSourceRegistry & ContentRepository facade
220.     │   ├── sources/                   # Bundled defaults & Custom source adapters
221.     │   ├── ingestion/                 # Manifest parser, ZipSlipGuard, Offline & Online loaders
222.     │   └── providers/                 # Riverpod bindings for dynamic sources
223.     ├── providers/                     # Riverpod state management
    │   └── app_providers.dart         # Database, active preset, & queue providers
    ├── scheduling/                    # Spaced repetition logic
    │   └── fsrs_scheduler.dart        # FSRS algorithm implementation
    ├── services/                      # Application business logic
    │   ├── exercise_engine.dart       # Pure exercise builder & distractor generator
    │   ├── feedback_service.dart      # Haptic & audio feedback triggers
    │   └── speech_service.dart        # Flutter TTS speech synthesis & voice checks
    └── ui/                            # Presentation layer
        ├── canvas/                    # 3-layer CustomPainter handwriting canvas
        ├── screens/                   # Home, Practice, Settings, Attributions
        └── widgets/                   # AudioPromptCard, MultipleChoiceCard, PresetSelector
```

### 5.2 Reactive Data Flow Diagram

```
[User Draws Stroke on Canvas]
         │
         ▼
[KanjiCanvas / StrokeMatcher] ────► Evaluates Fréchet distance against 50 reference points
         │
    (Stroke Accepted)
         │
         ▼
[PracticeScreen / ExerciseEngine] ──► Checks if all strokes are complete
         │
   (Kanji Finished)
         │
         ▼
[FSRSScheduler] ──────────────────► Maps (mistakes, hintsUsed) to FSRS Rating (Easy/Good/Hard/Again)
         │
         ▼
[UserDatabase (SQLite)] ──────────► Updates srs_cards table & writes review_logs
         │
         ▼
[Riverpod State Provider] ────────► Triggers queue refresh & updates Home Screen statistics
```

---

## Chapter 6: Troubleshooting & Real-World Lessons

### 1. The `ja-JP` TTS Voice Requirement
- **Symptom**: Red warning banner on audio exercises stating *"Japanese TTS voice not found"*.
- **Why it happens**: Operating systems (Android/Windows) only pre-install the user's primary language (e.g. English) to save device disk space.
- **The Lesson**: Always provide graceful, informative user-facing banners rather than crashing or failing silently when third-party system components are missing.

### 2. Widget Test Scrolling (`ensureVisible`)
- **Symptom**: Flutter integration tests fail with `FlutterError: A RenderFlex overflowed...` or `StateError: Bad state: No element`.
- **Why it happens**: In widget tests, the default virtual test screen is $800 \times 600$. Widgets positioned lower in a `SingleChildScrollView` or `ListView` are not mounted or cannot receive tap events until scrolled into view.
- **The Lesson**: Always use `await tester.ensureVisible(finder)` or `await tester.scrollUntilVisible(finder, 100)` before interacting with off-screen UI elements in automated tests.

### 3. Atomic Database Updates
- **Symptom**: If the app is updated with new kanji definitions, how do we update the database without corrupting user progress?
- **The Solution**: We store dictionary data in `assets/db/kanji_content.db` with a version stamp (`content_version`). When a newer version is bundled, the app copies it to `kanji_content.db.tmp` and performs an **atomic OS rename** over the old file. The user's study history in `user_progress.db` is completely separate and untouched.

---

## Chapter 7: How to Explain Tsuzuri (Portfolio & Interview Guide)

If you are discussing Tsuzuri in a portfolio review, engineering interview, or peer presentation, here is how to frame it clearly and professionally:

### The 60-Second Elevator Pitch
> *"Tsuzuri is a cross-platform, 100% offline-first Japanese Kanji learning application built in Flutter and Dart. Instead of relying on cloud servers or heavy neural networks, it uses discrete Fréchet distance algorithms to verify hand-drawn stroke geometry and order in real time against canonical KanjiVG paths. Long-term memory retention is driven by an implementation of the modern FSRS (Free Spaced Repetition Scheduler) algorithm, featuring multi-skill isolation between writing and reading modalities."*

### 5 Key Engineering Highlights to Showcase

1. **Deterministic Stroke Matching vs. Heavy ML**:
   - Explain how you used arc-length resampling, chord angle gates, and discrete Fréchet distance matrices to achieve instantaneous, sub-millisecond stroke verification with zero false positives—all running on pure Dart without GPU dependencies.
2. **Offline-First Architecture & Dual SQLite Pattern**:
   - Highlight the architectural decision to separate read-only dictionary data (`kanji_content.db`) from mutable user progress (`user_progress.db`), enabling atomic dictionary updates without risk to user review history.
3. **Multi-Skill FSRS Isolation**:
   - Explain why memory stability for writing recall must be isolated from recognition quizzes, preventing assisted modes (like watermark tracing) from corrupting spaced-repetition intervals.
4. **Universal Exercise Abstraction**:
   - Discuss how decomposing exercises into sealed `ExercisePrompt` and `ExerciseAnswerMethod` hierarchies made it simple to expand from a single writing canvas to 8 distinct practice presets across writing, reading, and audio.
5. **Plug-and-Play Modular Source Architecture**:
   - Explain how you decoupled character metadata, stroke points, and audio into orthogonal interfaces (`IKanjiMetadataSource`, `IKanjiStrokeSource`, `IKanjiAudioSource`), with a priority registry and fallback facade that allows users to import custom offline ZIP packages or stream online content without corrupting FSRS learning history.
6. **Production Verification & Testing Rigor**:
   - Emphasize the automated testing suite: **382 integration, unit, adversarial, and E2E tests** covering regression locks, FSRS calculations, audio speed toggling, zip-slip security guards, and multi-skill database migrations.
