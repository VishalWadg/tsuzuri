# Project: Tsuzuri Modular Content Source System

## Architecture
Tsuzuri's modular content source architecture decouples the legacy monolithic `ContentDatabase` into three orthogonal provider interfaces coordinated by a prioritized `ContentSourceRegistry` and accessed via a unified `ContentRepository` facade. Spaced repetition state (FSRS cards and review logs in `user_progress.db`) remains universally keyed by standard Unicode scalar integer `codepoint`, mathematically guaranteeing zero progress corruption across custom source additions, swaps, updates, or deactivations.

```
                      ┌───────────────────────────────────────┐
                      │          UI / Practice Layer          │
                      │   (HomeScreen, PracticeScreen, FSRS)  │
                      └──────────────────┬────────────────────┘
                                         │
                                         ▼
                      ┌───────────────────────────────────────┐
                      │       ContentRepository (Facade)      │
                      └──────────────────┬────────────────────┘
                                         │
                                         ▼
                      ┌───────────────────────────────────────┐
                      │        ContentSourceRegistry          │
                      │  - Active source priorities           │
                      │  - Fallback orchestration             │
                      └───────┬──────────┼──────────┬─────────┘
                              │          │          │
            ┌─────────────────┘          │          └─────────────────┐
            ▼                            ▼                            ▼
┌─────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────────┐
│   IKanjiMetadataSource  │  │    IKanjiStrokeSource   │  │    IKanjiAudioSource    │
├─────────────────────────┤  ├─────────────────────────┤  ├─────────────────────────┤
│ • Custom JSON Source    │  │ • Custom SVG/JSON Pkg   │  │ • Pre-recorded Files    │
│ • Custom SQLite Source  │  │ • Custom Vector Source  │  │ • Remote Audio Stream   │
│ • Bundled Metadata (Def)│  │ • Bundled Strokes (Def) │  │ • Default TTS Voice(Def)│
└─────────────────────────┘  └─────────────────────────┘  └─────────────────────────┘
```

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Pluggable Source Abstraction | Modular provider interfaces (`IKanjiMetadataSource`, `IKanjiStrokeSource`, `IKanjiAudioSource`) separating metadata, stroke vectors, and audio | M1 | ORIGINAL_REQUEST §R1 |
| 2 | Bundled Default Adapters | Zero-configuration bundled adapters (`BundledMetadataSource`, `BundledStrokeSource`, `DefaultTtsAudioSource`) wrapping `ContentDatabase` and `ISpeechService` | M1 | ORIGINAL_REQUEST §R1 |
| 3 | Content Source Registry & Repository Facade | Central registry prioritizing active sources with automatic multi-tier fallback to bundled defaults | M2 | ORIGINAL_REQUEST §R1 |
| 4 | Independent Component Fallback | Seamless independent substitution (e.g., custom metadata + bundled strokes + custom audio, or missing entry fallback) | M2 | ORIGINAL_REQUEST §R1 |
| 5 | FSRS & User Progress Invariance | Preservation of FSRS cards and review logs keyed by `(codepoint, mode)`, safe skipping of unresolvable cards in queue | M2 | ORIGINAL_REQUEST §R3 |
| 6 | Package Manifest Specification & Parser | Manifest schema defining package metadata, versioning, author, capabilities, and file layout | M3 | ORIGINAL_REQUEST §R2 |
| 7 | Source Validator & Security Gate | Deep validation of package integrity, Unicode scalar sanity, stroke count/blob conformity, and Zip-Slip path-traversal prevention | M3 | ORIGINAL_REQUEST §R2 |
| 8 | Offline Package Ingestion | Ingestion of offline directory, JSON, or archive packages with atomic staging and rollback on failure | M3 | ORIGINAL_REQUEST §R2 |
| 9 | Online Source Ingestion | Remote HTTP manifest fetching, caching, timeout/retry handling, and graceful failure recovery | M3 | ORIGINAL_REQUEST §R2 |
| 10 | Non-Destructive Error Handling | Structured error codes and user-friendly validation error messages without corrupting app or user data | M3 | ORIGINAL_REQUEST §R2 |
| 11 | Synthetic Sample Packages & Mock HTTP Infrastructure | Dynamic test package fixtures (valid, malformed, partial, security exploits) and embedded loopback HTTP mock server | E2E | ORIGINAL_REQUEST Verification |
| 12 | Opaque-Box E2E Test Suite (Tiers 1-4) | Comprehensive test suite covering features (Tier 1), boundaries (Tier 2), cross-feature pairs (Tier 3), and real-world workloads (Tier 4) | E2E | ORIGINAL_REQUEST Acceptance |
| 13 | Final Integration, Test Pass & Regression Baseline | 100% pass of E2E test suite + all 88 existing regression baseline tests passing + adversarial coverage audit | M4 | ORIGINAL_REQUEST Acceptance |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| E2E | E2E Testing Track | Synthetic sample packages, local loopback mock HTTP server, 4-tier opaque-box test suite, publishing TEST_READY.md | none | PLANNED |
| M1 | Modular Source Abstraction & Bundled Adapters | Abstract provider contracts, domain models, bundled metadata/stroke/audio source adapters, and unit tests | none | DONE |
| M2 | Fallback Chain, Registry & Repository Facade | Priority-based source registry, composite repository facade, Riverpod providers, independent component fallback, and FSRS progress compatibility | M1 | DONE |
| M3 | Ingestion Pipeline, Validation & Security | Manifest parsing, source validator (integrity, schema, Zip-Slip), offline loader (atomic staging), online HTTP loader, and typed error handling | M2 | DONE |
| M4 | Final Integration, E2E Test Pass & Hardening | Pass 100% of E2E test suite (Tiers 1-4), adversarial test coverage hardening, 88 baseline regression test pass, and victory audit | M3, E2E | PLANNED |

## Interface Contracts

### M1: Modular Contracts
```dart
abstract interface class IKanjiMetadataSource {
  String get sourceId;
  String get displayName;
  String get version;
  bool get isBundledDefault;
  Future<KanjiMetadataEntry?> getMetadata(int codepoint);
  Future<List<int>> getAllCodepoints();
  Future<int> getCharacterCount();
  Future<List<String>> generateMeaningDistractors(KanjiMetadataEntry target, {int count = 3});
  Future<List<String>> generateReadingDistractors(KanjiMetadataEntry target, {int count = 3});
}

abstract interface class IKanjiStrokeSource {
  String get sourceId;
  String get displayName;
  String get version;
  bool get isBundledDefault;
  Future<List<ReferenceStroke>?> getStrokes(int codepoint);
  Future<bool> containsStrokes(int codepoint);
}

enum AudioPayloadType { localFile, asset, remoteUrl, ttsFallback }

class AudioPronunciation {
  final AudioPayloadType type;
  final String uriOrText;
  final String? mimeType;
  final String reading;
  const AudioPronunciation({
    required this.type,
    required this.uriOrText,
    this.mimeType,
    required this.reading,
  });
}

abstract interface class IKanjiAudioSource {
  String get sourceId;
  String get displayName;
  String get version;
  bool get isBundledDefault;
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading});
  Future<bool> containsAudio(int codepoint, {String? reading});
}
```

### M2: Registry & Repository Facade
```dart
class ContentSourceRegistry {
  void registerMetadataSource(IKanjiMetadataSource source, {int priority = 0});
  void registerStrokeSource(IKanjiStrokeSource source, {int priority = 0});
  void registerAudioSource(IKanjiAudioSource source, {int priority = 0});
  void unregisterSource(String sourceId);
  List<IKanjiMetadataSource> get activeMetadataSources;
  List<IKanjiStrokeSource> get activeStrokeSources;
  List<IKanjiAudioSource> get activeAudioSources;
}

class ContentRepository {
  final ContentSourceRegistry registry;
  ContentRepository({required this.registry});

  Future<KanjiCharacter?> getKanjiByCodepoint(int codepoint);
  Future<List<KanjiCharacter>> getAllKanjiOrdered();
  Future<AudioPronunciation> resolveAudio(int codepoint, {String? reading});
  Future<int> getTotalCharacterCount();
}
```

### M3: Ingestion & Validation
```dart
enum IngestionErrorCode {
  invalidArchive,
  securityPathTraversal,
  missingManifest,
  schemaMismatch,
  corruptedData,
  networkError,
  checksumMismatch,
}

class IngestionResult {
  final bool isSuccess;
  final String? sourceId;
  final IngestionErrorCode? errorCode;
  final String? errorMessage;
  const IngestionResult.success(this.sourceId)
      : isSuccess = true, errorCode = null, errorMessage = null;
  const IngestionResult.failure(this.errorCode, this.errorMessage)
      : isSuccess = false, sourceId = null;
}
```

## Code Layout
```
lib/src/content/
├── contracts/
│   ├── kanji_metadata_source.dart     # IKanjiMetadataSource & KanjiMetadataEntry
│   ├── kanji_stroke_source.dart       # IKanjiStrokeSource
│   └── kanji_audio_source.dart        # IKanjiAudioSource & AudioPronunciation
├── sources/
│   ├── bundled/
│   │   ├── bundled_metadata_source.dart # Wraps ContentDatabase
│   │   ├── bundled_stroke_source.dart   # Wraps ContentDatabase
│   │   └── default_tts_audio_source.dart# Wraps ISpeechService
│   ├── offline/
│   │   ├── json_content_source.dart   # Custom JSON source
│   │   └── sqlite_content_source.dart # Custom SQLite source
│   └── online/
│       └── http_content_source.dart   # Custom HTTP source with cache
├── ingestion/
│   ├── source_manifest.dart           # SourceManifest & parser
│   ├── source_validator.dart          # Integrity & Zip-Slip validator
│   ├── offline_package_loader.dart    # Directory/archive staging loader
│   └── online_source_fetcher.dart     # HTTP fetcher with timeout/retry
├── registry/
│   ├── content_source_registry.dart   # Priority-based registry & fallback
│   └── content_repository.dart        # Unified composite repository facade
└── providers/
    └── content_source_providers.dart  # Riverpod providers
```
