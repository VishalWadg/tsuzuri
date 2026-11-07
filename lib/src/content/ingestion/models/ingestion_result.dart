import 'source_manifest.dart';

/// Error codes identifying reasons for ingestion or validation failures.
enum IngestionErrorCode {
  invalidArchive,
  securityPathTraversal,
  zipSlipDetected,
  missingManifest,
  invalidManifest,
  missingRequiredField,
  unsupportedVersion,
  missingAssetFile,
  invalidCodepoint,
  schemaMismatch,
  corruptedData,
  corruptArchive,
  invalidStrokeData,
  invalidAudioData,
  checksumMismatch,
  networkError,
  timeout,
  storageError,
}

/// Result of an offline package or online source ingestion operation.
class IngestionResult {
  /// Whether ingestion was successful.
  final bool isSuccess;

  /// Parsed and validated manifest of the ingested source package (if successful).
  final SourceManifest? manifest;

  /// Promoted local filesystem directory of the package (if successful).
  final String? packageDirectory;

  /// Specific error code describing the failure (if failed).
  final IngestionErrorCode? errorCode;

  /// Human-readable diagnostic error message (if failed).
  final String? errorMessage;

  /// Optional contextual details or underlying error (if failed).
  final dynamic errorDetails;

  final String? _sourceId;

  /// Creates a successful ingestion result with package manifest and directory.
  const IngestionResult.success({
    this.manifest,
    this.packageDirectory,
    String? sourceId,
  })  : isSuccess = true,
        _sourceId = sourceId,
        errorCode = null,
        errorMessage = null,
        errorDetails = null;

  /// Convenience constructor for success with just a source ID.
  const IngestionResult.withSourceId(String sourceId)
      : isSuccess = true,
        manifest = null,
        packageDirectory = null,
        _sourceId = sourceId,
        errorCode = null,
        errorMessage = null,
        errorDetails = null;

  /// Creates a failed ingestion result with typed error code and diagnostic message.
  const IngestionResult.failure({
    required IngestionErrorCode this.errorCode,
    required String this.errorMessage,
    this.errorDetails,
  })  : isSuccess = false,
        manifest = null,
        packageDirectory = null,
        _sourceId = null;

  /// Unique identifier of the package.
  String? get sourceId => manifest?.id ?? _sourceId;

  @override
  String toString() {
    if (isSuccess) {
      return 'IngestionResult.success(sourceId: $sourceId, path: $packageDirectory)';
    } else {
      return 'IngestionResult.failure(code: $errorCode, message: "$errorMessage")';
    }
  }
}
