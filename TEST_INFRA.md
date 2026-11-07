# E2E Test Infra: Tsuzuri Modular Content Source System

## Test Philosophy
- Opaque-box, requirement-driven. Derived from `ORIGINAL_REQUEST.md` and user-facing specifications, completely decoupled from internal database table layout.
- Methodology: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World Workload Testing.
- Zero external network dependencies: Embedded loopback `HttpServer.bind(InternetAddress.loopbackIPv4, 0)` for online testing.
- Dynamic fixtures: `TestPackageBuilder` generates valid, malformed, partial, and malicious (Zip-Slip) offline packages in temp sandboxes without checking binary blobs into git.

## Feature Inventory
| # | Feature | Source (Requirement) | Tier 1 | Tier 2 | Tier 3 |
|---|---------|---------------------|:------:|:------:|:------:|
| 1 | Pluggable Source Abstraction | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 2 | Bundled Default Adapters | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 3 | Source Registry & Fallback Chain | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 4 | Independent Component Substitution | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 5 | FSRS & User Progress Integrity | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| 6 | Manifest Schema & Parsing | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 7 | Source Validator & Security Gate | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 8 | Offline Package Ingestion | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 9 | Online HTTP Ingestion & Caching | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 10 | Non-Destructive Error Handling | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |

## Test Architecture
- **Test Runner**: `flutter test test/content/` (and full regression baseline `flutter test`)
- **Test Harness Components**:
  - `test/content/fixtures/test_package_builder.dart`: Programmatic generator for valid, malformed, truncated, checksum-mismatched, and Zip-Slip packages.
  - `test/content/fixtures/test_http_mock_server.dart`: Local loopback HTTP mock server simulating 200, 304, 404, 500, timeouts, and network drops.
  - `test/content/fixtures/mock_custom_sources.dart`: In-memory implementations of `IKanjiMetadataSource`, `IKanjiStrokeSource`, and `IKanjiAudioSource` for deterministic multi-source testing.

## Test Tiers & Target Counts
- **Tier 1 - Feature Coverage**: 50 test cases (5 per feature across F1-F10)
  - Isolated verification of metadata, stroke, and audio source contracts, manifest parsing, offline loader, online fetcher, registry registration, and FSRS progress preservation.
- **Tier 2 - Boundary & Corner Cases**: 50 test cases (5 per feature across F1-F10)
  - Edge cases: Unicode scalar boundaries (U+0001, U+10FFFF, surrogates), empty strings/readings, 0 or 64 stroke limits, malformed 399/401 byte blobs, Zip-Slip path traversal (`../../`), offline archive corruption, network timeouts, 500 server errors.
- **Tier 3 - Cross-Feature Combinations**: 15 test cases (Pairwise interactions)
  - Multi-source layering: Custom metadata + Bundled strokes + Custom audio.
  - Partial packages: Missing Kanji in custom source seamlessly falling back to default.
  - Online source failover: Remote HTTP failure falling back to cached or bundled defaults.
  - Source deactivation: Disabling custom source leaves FSRS card progress intact.
- **Tier 4 - Real-World Application Scenarios**: 8 test cases
  - End-to-end user workflows: User imports JLPT N1 supplement package, practices daily queue, reviews cards, updates package, restarts app, and uninstalls package while maintaining complete FSRS scheduling integrity.
- **Total Minimum Target**: ~123 test cases.

## Acceptance Criteria Gate
1. All new E2E tests pass with exit code 0 (`flutter test test/content/`).
2. All 88 existing baseline tests continue to pass with 0 regressions (`flutter test`).
3. `TEST_READY.md` published upon completion of test suite.
