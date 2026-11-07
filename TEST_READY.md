# TEST_READY — Tsuzuri Modular Content Source System

**Publication Date:** 2026-11-07  
**Test Suite Status:** READY / VERIFIED  
**Integrity Mode:** Development  
**Analyzer Issues:** 0  
**Test Execution Results:**
- `test/content/e2e_content_source_system_test.dart`: **123 / 123 PASSED** (100%)
- `test/content/` (Content Source domain suite): **294 / 294 PASSED** (100%)
- Full Repository Regression Baseline (`flutter test`): **382 / 382 PASSED** (100%, 0 regressions)

---

## 1. Test Runner & Verification Commands

All test suites execute hermetically without external network calls or cloud dependencies.

### Static Analysis
```bash
flutter analyze
# Expected: "No issues found!"
```

### Dedicated E2E Content Source System Suite (Tiers 1–4)
```bash
flutter test test/content/e2e_content_source_system_test.dart
# Runs 123 opaque-box E2E tests across all 4 tiers
```

### Full Content Domain Test Suite
```bash
flutter test test/content/
# Runs all 294 tests covering unit contracts, adapters, ingestion, validation, adversarial stress, and E2E
```

### Full Repository Regression Baseline
```bash
flutter test
# Runs entire test suite (382 tests) including database, UI widgets, audio flows, FSRS scheduling, presets, and content engine
```

---

## 2. Test Architecture & Harness

The end-to-end test harness operates with zero external network dependencies and dynamic sandbox generation:

- **Loopback Mock HTTP Server (`MockContentHttpServer`)**:
  - Bound dynamically to `HttpServer.bind(InternetAddress.loopbackIPv4, 0)` with ephemeral port allocation.
  - Simulates HTTP 200, 304 Not Modified, 404 Not Found, 500 Internal Error, 503 Unavailable, network timeouts, closed-port connection refusal, and corrupted body stream drops.
- **Dynamic Package Fixture Generator (`TestPackageBuilder`)**:
  - Programmatically constructs synthetic ZIP packages and directory structures in isolated temporary sandboxes (`Directory.systemTemp.createTemp()`).
  - Generates valid packages, schema-invalid manifests, truncated archives, checksum mismatches, and adversarial Zip-Slip path traversal exploits (`../../`) without checking binary blobs into git.
- **In-Memory Source Doubles (`mock_custom_sources.dart`)**:
  - Implements `IKanjiMetadataSource`, `IKanjiStrokeSource`, and `IKanjiAudioSource` for deterministic multi-source priority chains and fault injection.
  - Implements `FakeSpeechService` for hermetic Japanese TTS fallback assertions.

---

## 3. Tier Breakdown & Test Inventory

### Tier 1: Feature Coverage (50 Test Cases — F1 through F10)
Isolated verification of fundamental feature contracts and fallback hooks:

| Feature ID | Feature Name | Test Cases | Pass/Total |
|---|---|---|:---:|
| **F1** | Pluggable Source Abstraction | T1-F1-01 to T1-F1-05 | 5 / 5 |
| **F2** | Bundled Default Adapters | T1-F2-01 to T1-F2-05 | 5 / 5 |
| **F3** | Source Registry & Fallback Chain | T1-F3-01 to T1-F3-05 | 5 / 5 |
| **F4** | Independent Component Substitution | T1-F4-01 to T1-F4-05 | 5 / 5 |
| **F5** | FSRS & User Progress Integrity | T1-F5-01 to T1-F5-05 | 5 / 5 |
| **F6** | Manifest Schema & Parsing | T1-F6-01 to T1-F6-05 | 5 / 5 |
| **F7** | Source Validator & Security Gate | T1-F7-01 to T1-F7-05 | 5 / 5 |
| **F8** | Offline Package Ingestion | T1-F8-01 to T1-F8-05 | 5 / 5 |
| **F9** | Online HTTP Ingestion & Caching | T1-F9-01 to T1-F9-05 | 5 / 5 |
| **F10** | Non-Destructive Error Handling | T1-F10-01 to T1-F10-05 | 5 / 5 |
| **Subtotal** | | | **50 / 50** |

- **T1-F1-01 to 05**: `IKanjiMetadataSource`, `IKanjiStrokeSource`, `IKanjiAudioSource` contracts; distractor generation; codepoints retrieval; provider identity immutability.
- **T1-F2-01 to 05**: `BundledMetadataSource`, `BundledStrokeSource`, `DefaultTtsAudioSource` backed by bundled SQLite database; total Joyo kanji count oracle verification.
- **T1-F3-01 to 05**: Registry descending priority ordering; custom overriding bundled; bundled permanently pinned at tail; safe unregistration reverting queries immediately.
- **T1-F4-01 to 05**: Independent component mixing: Custom Metadata + Bundled Strokes + Custom Audio; partial source fallback to bundled per component.
- **T1-F5-01 to 05**: Spaced repetition invariance: FSRS card progress persists invariant when custom sources are attached, modified, or detached; safe queue omission for dangling cards.
- **T1-F6-01 to 05**: `SourceManifest.fromJson` parser; missing fields rejection; SemVer compliance; empty capabilities rejection; slug syntax validation.
- **T1-F7-01 to 05**: Deep structural validator: schema map validation, Zip-Slip path traversal detection, Unicode scalar boundaries (no surrogates), stroke range `[1, 64]`, audio magic bytes (WAV/MP3).
- **T1-F8-01 to 05**: Offline ingestion from ZIP archive, directory tree, standalone JSON; atomic staging rollback on invalid archive; dynamic source instantiation.
- **T1-F9-01 to 05**: Online HTTP fetcher: loopback download, 404/500 error mapping, checksum verification, promotion to repository.
- **T1-F10-01 to 05**: Non-destructive fault handling: `IngestionResult.failure` error codes, active registry immunity under corrupt import, user progress immunity under fault, provider exception containment.

---

### Tier 2: Boundary & Corner Cases (50 Test Cases — F1 through F10)
Stress tests on extreme inputs, edge values, corrupted states, and security bounds:

| Boundary Group | Description | Test Cases | Pass/Total |
|---|---|---|:---:|
| **F1 Boundaries** | Unicode Scalars & Empty Fields | T2-F1-01 to T2-F1-05 | 5 / 5 |
| **F2 Boundaries** | Bundled Defaults & Codepoint Limits | T2-F2-01 to T2-F2-05 | 5 / 5 |
| **F3 Boundaries** | Extreme Priorities & Registry Edges | T2-F3-01 to T2-F3-05 | 5 / 5 |
| **F4 Boundaries** | Component Partiality & Cache Invalidation | T2-F4-01 to T2-F4-05 | 5 / 5 |
| **F5 Boundaries** | FSRS Extremes & Repetition Loops | T2-F5-01 to T2-F5-05 | 5 / 5 |
| **F6 Boundaries** | Manifest Schema Extremes & SemVer Edges | T2-F6-01 to T2-F6-05 | 5 / 5 |
| **F7 Boundaries** | Stroke Counts, Blobs & Audio Size | T2-F7-01 to T2-F7-05 | 5 / 5 |
| **F8 Boundaries** | Empty/Truncated Archives & Rollback | T2-F8-01 to T2-F8-05 | 5 / 5 |
| **F9 Boundaries** | HTTP Timeouts, 404, 500, Refused Ports | T2-F9-01 to T2-F9-05 | 5 / 5 |
| **F10 Boundaries** | Error Code Mapping & Concurrency | T2-F10-01 to T2-F10-05 | 5 / 5 |
| **Subtotal** | | | **50 / 50** |

- **T2-F1-01 to 05**: Scalar boundary U+0001; maximum scalar U+10FFFF; surrogate code points U+D800/U+DFFF return null; empty string fields in `KanjiMetadataEntry`; single stroke kanji '一' (0x4E00) stroke precision with 50 point samples.
- **T2-F2-01 to 05**: Negative codepoint query (-1); codepoint 0 query; non-existent stroke query; empty reading string fallback; prevention of bundled default unregistration (`UnsupportedError`).
- **T2-F3-01 to 05**: Priority extremes (`int.maxFinite`, negative priorities); duplicate registration priority updates; unregistering non-existent source ID; FIFO tie-breaking on equal priorities; `clearCustomSources()` keeping bundled intact.
- **T2-F4-01 to 05**: Partial custom source with empty meanings list; 5-level custom metadata priority stack; stroke source returning empty list falls back to next provider; null reading + unknown codepoint generates safe audio fallback; cache invalidation on unregister.
- **T2-F5-01 to 05**: Initial scheduling state (elapsedDays=0, reps=0, state New); extreme stability and difficulty values; querying due cards when all due dates are in future; card referencing codepoints beyond bundled set persists without FK errors; 20-rep sequential review loop maintaining monotonic stability.
- **T2-F6-01 to 05**: Manifest `formatVersion` bounds (0 or 2 throw `FormatException`); ID length boundary (128 valid, 129 rejected); SemVer with pre-release tags (`1.0.0-beta.1+build.123`); unknown JSON fields preserved/ignored; whitespace-padded string fields safely trimmed.
- **T2-F7-01 to 05**: Stroke count limits (64 accepted, 65 rejected); stroke points blob boundary (400 bytes accepted, 399/401 rejected); NaN/Infinity coordinates rejected; Zip-Slip path variations (`../`, `..\`, nested traversal) blocked; audio file size bounds (31 bytes rejected, 32 bytes valid).
- **T2-F8-01 to 05**: Empty ZIP archive (0 files) returns `missingManifest`; missing declared asset file returns `missingAssetFile`; non-existent archive path returns `missingAssetFile`; 0-byte archive returns `invalidArchive`; path normalization in nested directory packages.
- **T2-F9-01 to 05**: 1ms instant timeout triggers `timeout`; closed port (connection refused) triggers `networkError`; malformed JSON manifest body returns `invalidManifest`; corrupted/truncated asset stream returns `networkError`; HTTP 503 Service Unavailable retries and terminates gracefully.
- **T2-F10-01 to 05**: Ingestion failure leaves no lock on `UserDatabase`; concurrent staging creations produce isolated unique folders; custom source throwing in `getAllCodepoints` contained; custom source throwing in `generateMeaningDistractors` falls back to bundled; re-registering previously unregistered source works safely.

---

### Tier 3: Cross-Feature Combinations (15 Test Cases: T3-01 to T3-15)
Multi-source layering, pairwise feature interactions, and failover mechanics:

| Test ID | Interaction Pair | Scenario | Result |
|---|---|---|:---:|
| **T3-01** | F1 + F8 | Offline ZIP package ingested -> Extracted and registered as Metadata & Stroke sources | PASS |
| **T3-02** | F2 + F3 + F4 | Layer custom metadata over bundled strokes and bundled audio | PASS |
| **T3-03** | F3 + F9 | Ingest online package over HTTP -> Falls back to bundled for non-included kanji | PASS |
| **T3-04** | F4 + F5 | User practices writing mode on Kanji with custom strokes; swapping strokes preserves FSRS state | PASS |
| **T3-05** | F5 + F8 | User reviews custom kanji in v1 package; updates package to v2; card progress preserved | PASS |
| **T3-06** | F3 + F5 | Unregistering custom source safely omits card from queue; re-registering restores card | PASS |
| **T3-07** | F6 + F7 + F8 | Manifest specifies invalid metadata path; validator rejects; staging rolled back | PASS |
| **T3-08** | F6 + F7 + F8 | Malicious archive with Zip-Slip path traversal rejected; zero files written outside staging | PASS |
| **T3-09** | F7 + F9 | Online fetcher downloads archive with SHA-256 checksum in manifest; mismatch rejected | PASS |
| **T3-10** | F7 + F10 | Path traversal attack fails gracefully with clear error code; database unaffected | PASS |
| **T3-11** | F3 + F8 + F9 | Offline Package A and Online Package B active simultaneously with priority ordering | PASS |
| **T3-12** | F4 + F9 + F10 | Remote HTTP 500 error during update leaves existing offline sources serving smoothly | PASS |
| **T3-13** | F1 + F4 + F5 | Audio-only custom source added and removed; reading/recognition cards invariant | PASS |
| **T3-14** | F7 + F8 + F3 | Offline package with surrogate codepoints rejected by validator; valid accepted | PASS |
| **T3-15** | F5 + F8 + F9 | Heterogeneous session: User reviews cards across Bundled, Offline, and Online sources | PASS |
| **Subtotal** | | | **15 / 15** |

---

### Tier 4: Real-World Application Scenarios (8 Test Cases: T4-01 to T4-08)
Complete user journeys and production workflows:

| Test ID | Lifecycle Scenario | Result |
|---|---|:---:|
| **T4-01** | **End-to-End Fresh Install**: Bundled zero-config defaults, initial study queue, first review log | PASS |
| **T4-02** | **End-to-End JLPT N1 Expansion Import**: ZIP archive ingestion expands character dictionary | PASS |
| **T4-03** | **End-to-End Study Session on Expansion Content**: FSRS review, due date, and log recording | PASS |
| **T4-04** | **End-to-End In-Place Package Update (v1.0 -> v2.0)**: Preserves FSRS card history and updates definitions | PASS |
| **T4-05** | **End-to-End Remote Community Source Sync**: HTTP fetch, asset cache, audio playback resolution | PASS |
| **T4-06** | **End-to-End Package Deactivation & Re-Activation**: Queue safety and historical invariance | PASS |
| **T4-07** | **End-to-End Adversarial Recovery**: Corrupt download fails cleanly; ongoing learning session unharmed | PASS |
| **T4-08** | **End-to-End Full Hybrid Lifecycle**: Bundled -> Offline Import -> Online Fetch -> Priority Switch -> Sync | PASS |
| **Subtotal** | | **8 / 8** |

---

## 4. Acceptance Criteria Verification Checklist

| Requirement | Acceptance Criterion | Verification Method | Status |
|---|---|---|:---:|
| **R1. Modularity** | Custom source provider interfaces allow independent registration and swapping of metadata, stroke, and audio sources. | Tier 1 (F1, F4), Tier 3 (T3-02, T3-13) | **VERIFIED** |
| **R1. Fallback** | Absent entries in custom source automatically fall back to bundled defaults without runtime errors or crashes. | Tier 1 (F2, F3), Tier 2 (F2, F4), Tier 3 (T3-03) | **VERIFIED** |
| **R2. Offline Ingestion** | Ingestion parses and loads valid synthetic offline packages (ZIP/directory/JSON) with metadata, stroke paths, audio files. | Tier 1 (F8), Tier 2 (F8), Tier 4 (T4-02) | **VERIFIED** |
| **R2. Online Ingestion** | Online ingestion fetches, validates, and activates content from remote HTTP endpoints with caching. | Tier 1 (F9), Tier 2 (F9), Tier 4 (T4-05) | **VERIFIED** |
| **R2. Validation & Security** | Malformed packages, checksum errors, or Zip-Slip attacks rejected gracefully with clear error codes and zero orphan staging. | Tier 1 (F6, F7, F10), Tier 2 (F7, F8, F9), Tier 3 (T3-07, T3-08, T3-10) | **VERIFIED** |
| **R3. Progress Integrity** | FSRS spaced repetition cards and review logs remain consistent and operable across source addition, update, or removal. | Tier 1 (F5), Tier 2 (F5, F10), Tier 3 (T3-04, T3-05, T3-06, T3-15), Tier 4 (T4-03, T4-04, T4-06) | **VERIFIED** |
| **Regression Baseline** | All existing test suites in repository continue to pass with no regressions. | Full repository `flutter test` (382 / 382 passed) | **VERIFIED** |

---

## 5. Summary & Sign-off

The modular content source system for Tsuzuri has been thoroughly verified against all requirements set forth in `ORIGINAL_REQUEST.md`, `TEST_INFRA.md`, and `PROJECT.md`. The 4-tier E2E test suite executes deterministically in **6 seconds**, with **0 test defects**, **0 analyzer issues**, and **0 regressions** against the entire baseline test suite.
