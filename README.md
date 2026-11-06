# Tsuzuri (綴り) — Offline-First Japanese Kanji Practice & Learning System

[![Flutter Test Suite](https://img.shields.io/badge/Tests-88%20Passing-brightgreen.svg)](#automated-testing)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux-blue.svg)](#platform-support)
[![Architecture](https://img.shields.io/badge/Architecture-Offline--First%20%7C%20Dual%20SQLite%20%7C%20FSRS-orange.svg)](docs/PROJECT_GUIDEBOOK.md)

**Tsuzuri (綴り)** is a complete, production-grade, 100% offline-first Japanese Kanji learning and handwriting mastery application built with **Flutter**, **Dart**, and **SQLite**. 

Everything runs on your device with **zero server dependencies, zero accounts, and zero cloud tracking**.

---

## 📖 Complete Beginner Architecture Guide

For an in-depth, beginner-friendly walkthrough explaining the tech stack, mathematical algorithms, architectural decisions, and how to explain this project in interviews and portfolios, read the comprehensive guidebook:

👉 **[docs/PROJECT_GUIDEBOOK.md](docs/PROJECT_GUIDEBOOK.md)**

---

## Key Features & Capabilities

### 1. Advanced 5-Stage Stroke Recognition
- Real-time handwriting recognition on a 60/120fps `CustomPainter` canvas.
- Uses **Discrete Fréchet Distance** curve-matching rather than heavy neural networks, achieving sub-millisecond, deterministic verification.
- **5-Stage Verification Pipeline**: Length-Ratio Gate &rarr; Chord Direction Gate &rarr; Fréchet Distance Matrix &rarr; Dynamic Thresholding &rarr; Wrong-Order Detection.
- Live stroke snapping to reference SVG paths, directional error banners, and animated stroke demos on mistakes.

### 2. Dual Database Architecture
- **Read-Only Content DB (`assets/db/kanji_content.db`)**: Pre-compiled SQLite database with KANJIDIC2 character metadata, KanjiVG SVG paths, and pre-sampled 50-point binary blobs. Updated atomically on launch with version stamps without touching user data.
- **Writable User Progress DB (`user_progress.db`)**: Local SQLite database storing user review logs, FSRS scheduling states, writing metrics, and personal settings with versioned migrations (Schema v3).

### 3. Multi-Skill Spaced Repetition (FSRS)
- Powered by the **Free Spaced Repetition Scheduler (FSRS)**, mathematically superior to legacy SM-2/Anki algorithms.
- **Strict Skill Isolation**: Separate FSRS cards for `writingRecall`, `readingRecognition`, and `meaningRecognition` under `(codepoint, skill)`. Assisted practice (watermark tracing or stroke locking) never corrupts true free-recall memory stability.

### 4. 8 Curated Practice Presets (2 Activities)
Learners can seamlessly toggle between two learning activities right from the Home Screen:

| Activity | Preset Name | Prompt Type | Answer Method | FSRS Memory Impact |
| :--- | :--- | :--- | :--- | :--- |
| **Writing** | **Standard** | English Meaning | Free-Recall Handwriting | ✅ Advances Writing Stability |
| **Writing** | **Stroke Guide** | English Meaning | Stroke-Locked Handwriting | 🔒 Isolated Metrics Only |
| **Writing** | **Challenge** | English Meaning | Strict Leniency Handwriting | ✅ Advances Writing Stability |
| **Writing** | **Audio Immersion** | Spoken Japanese (TTS) | Free-Recall Handwriting | ✅ Advances Writing Stability |
| **Writing** | **Copy Practice** | English Meaning | Watermark Tracing Canvas | 🔒 Isolated Metrics Only |
| **Recognition** | **Kanji &rarr; Meaning** | Kanji Literal | 4-Choice English Meaning | ✅ Advances Meaning Stability |
| **Recognition** | **Kanji &rarr; Reading** | Kanji Literal | 4-Choice Kana Reading | ✅ Advances Reading Stability |
| **Recognition** | **Audio &rarr; Meaning** | Spoken Japanese (TTS) | 4-Choice English Meaning | ✅ Advances Meaning Stability |

### 5. Native Offline Speech & Audio (TTS)
- Integrated via `flutter_tts` connecting directly to on-device speech synthesis (Google Speech Services / Windows SAPI).
- Interactive `AudioPromptCard` with infinite replay, speed calibration (**Normal 0.5x** vs. **Slow 0.32x**), and autoplay guards.
- Informative user guidance when device `ja-JP` voice data needs to be enabled in OS settings.

### 6. Full Data Portability & Offline Backup
- Single-tap JSON export and import for complete user progress, review logs, and settings.
- Easy migration between devices without third-party servers.

---

## Project Structure

```
offline_kanji_practice/
├── assets/
│   ├── db/                            # Bundled prebuilt kanji_content.db & version stamp
│   └── images/                        # App branding & logo assets
├── docs/                              # Architecture documentation & milestone reports
│   ├── PROJECT_GUIDEBOOK.md           # The comprehensive beginner-friendly architecture guide
│   ├── M0_BASELINE_REPORT.md          # Baseline stabilization & regression test suite
│   ├── M1_ARCHITECTURE_PROPOSAL.md    # Universal exercise abstraction design
│   ├── M2_AUDIO_ARCHITECTURE_AND_DECISIONS.md # Speech service & TTS design
│   ├── M3_ADVANCED_WRITING_ARCHITECTURE_AND_PLAN.md # Watermarks, stroke locking & isolation
│   ├── M4_PRESETS_AND_CONFIG_ARCHITECTURE.md # Presets & configuration domain model
│   ├── M5_RECOGNITION_AND_MULTI_SKILL_ARCHITECTURE.md # Recognition quizzes & Schema v3
│   └── M6_FINAL_POLISH_AND_VERIFICATION.md # Activity switcher, backup & verification
├── lib/
│   ├── main.dart                      # App entry point
│   └── src/
│       ├── data/                      # Dual SQLite databases (content_db & user_db)
│       ├── domain/exercises/          # Abstract exercise definitions, prompts & presets
│       ├── matching/                  # Discrete Fréchet distance & stroke geometry
│       ├── providers/                 # Riverpod dependency injection & reactive state
│       ├── scheduling/                # FSRS spaced-repetition scheduler
│       ├── services/                  # Exercise engine, speech service, haptic feedback
│       └── ui/                        # CustomPainter canvas, screens & interactive widgets
├── test/                              # Automated integration and unit test suite (88 tests)
└── tools/                             # Python build pipeline & benchmarking tools
```

---

## Getting Started

### 1. Prerequisites
- **Flutter SDK**: `>=3.3.0`
- **Dart SDK**: `>=3.0.0`
- **Python 3**: `>=3.9` (optional: only needed if rebuilding content databases from raw KanjiVG/KANJIDIC2 XML)

### 2. Install & Run Tests
```bash
# Clone the repository
git clone https://github.com/VishalWadg/tsuzuri.git
cd tsuzuri

# Fetch Dart dependencies
flutter pub get

# Run the complete test suite (88/88 tests passing)
flutter test

# Verify code analysis (0 errors, 0 warnings)
flutter analyze
```

### 3. Launch the Application
```bash
# Run on your connected device, emulator, or desktop
flutter run
```

> **Note on Japanese Audio**: On your first launch of an audio exercise, if your device does not have Japanese voice data installed, follow the in-app banner to download **Japanese (ja-JP)** in your device's Text-to-Speech settings. Once downloaded, it works 100% offline forever.

---

## Attributions & Licensing

- **KanjiVG**: Stroke order diagrams and Bézier path data created by Ulrich Apel, licensed under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/).
- **KANJIDIC2**: Japanese dictionary file compiled by the Electronic Dictionary Research and Development Group (EDRDG), licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
