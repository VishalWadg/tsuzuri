import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models/source_manifest.dart';
import '../models/ingestion_result.dart';
import '../security/zip_slip_guard.dart';
import '../staging/package_staging_manager.dart';
import '../validation/source_validator.dart';

/// Configuration options for online source fetching.
class FetchOptions {
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final int maxRetries;
  final Duration retryDelay;
  final int maxPackageSizeBytes;
  final Map<String, String>? headers;

  const FetchOptions({
    this.connectTimeout = const Duration(seconds: 10),
    this.receiveTimeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    this.retryDelay = const Duration(milliseconds: 300),
    this.maxPackageSizeBytes = 50 * 1024 * 1024,
    this.headers,
  });
}

/// Fetches remote content packages over HTTP, downloads assets into isolated
/// staging sandbox, validates integrity, and promotes atomically.
class OnlineSourceFetcher {
  final HttpClient _client;
  final PackageStagingManager _stagingManager;
  final SourceValidator _validator;

  OnlineSourceFetcher({
    HttpClient? client,
    required PackageStagingManager stagingManager,
    required SourceValidator validator,
  })  : _client = client ?? HttpClient(),
        _stagingManager = stagingManager,
        _validator = validator;

  /// Fetches remote manifest, downloads contents into staging, validates, and promotes.
  Future<IngestionResult> fetchAndInstall(
    Uri manifestUri, {
    FetchOptions options = const FetchOptions(),
  }) async {
    // 1. Fetch manifest over HTTP with retry and timeout containment
    _HttpResponse? manifestResp;
    try {
      manifestResp = await _fetchWithRetry(manifestUri, options);
    } on TimeoutException {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.timeout,
        errorMessage: 'Connection to $manifestUri timed out after ${options.connectTimeout.inSeconds}s.',
      );
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.networkError,
        errorMessage: 'Network error fetching manifest from $manifestUri: $e',
      );
    }

    if (manifestResp.statusCode == HttpStatus.notFound) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.networkError,
        errorMessage: 'Remote manifest not found at $manifestUri (HTTP 404).',
      );
    }

    if (manifestResp.statusCode != HttpStatus.ok) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.networkError,
        errorMessage: 'Remote server returned HTTP ${manifestResp.statusCode} for $manifestUri.',
      );
    }

    // 2. Parse and validate manifest schema
    dynamic jsonMap;
    try {
      jsonMap = jsonDecode(manifestResp.bodyString);
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.invalidManifest,
        errorMessage: 'Malformed JSON in remote manifest: $e',
      );
    }

    if (jsonMap is! Map<String, dynamic>) {
      return const IngestionResult.failure(
        errorCode: IngestionErrorCode.invalidManifest,
        errorMessage: 'Remote manifest root must be a JSON object.',
      );
    }

    final schemaRes = _validator.validateManifest(jsonMap);
    if (!schemaRes.isValid) {
      return IngestionResult.failure(
        errorCode: schemaRes.errorCode!,
        errorMessage: schemaRes.errorMessage!,
      );
    }

    SourceManifest manifest;
    try {
      manifest = SourceManifest.fromJson(jsonMap);
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.invalidManifest,
        errorMessage: 'Manifest construction error: $e',
      );
    }

    // 3. Allocate staging directory
    final stagingDir = await _stagingManager.createStagingDirectory(manifest.id);

    try {
      // Write manifest.json
      final manifestFile = File(p.join(stagingDir.path, 'manifest.json'));
      await manifestFile.writeAsString(jsonEncode(manifest.toJson()));

      // 4. Download content assets
      final rawArchiveUrl = jsonMap['archiveUrl'] ?? jsonMap['archive_url'];
      if (rawArchiveUrl != null) {
        // Mode A: Single ZIP archive URL
        final archiveUri = manifestUri.resolve(rawArchiveUrl.toString());
        final archiveResp = await _fetchWithRetry(archiveUri, options);
        if (archiveResp.statusCode != HttpStatus.ok) {
          throw HttpException('HTTP ${archiveResp.statusCode} fetching package archive: $archiveUri');
        }

        Archive archive;
        try {
          archive = ZipDecoder().decodeBytes(archiveResp.bodyBytes, verify: true);
        } catch (e) {
          await _stagingManager.purgeStagingDirectory(stagingDir);
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.corruptArchive,
            errorMessage: 'Remote archive is corrupted or invalid ZIP: $e',
          );
        }

        try {
          await _stagingManager.extractArchive(archive, stagingDir);
        } on SecurityException catch (e) {
          await _stagingManager.purgeStagingDirectory(stagingDir);
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.zipSlipDetected,
            errorMessage: e.message,
          );
        }
      } else {
        // Mode B: Relative asset endpoints
        if (manifest.metadataPath != null) {
          final metaUri = manifestUri.resolve(manifest.metadataPath!);
          final resp = await _fetchWithRetry(metaUri, options);
          if (resp.statusCode != HttpStatus.ok) {
            throw HttpException('HTTP ${resp.statusCode} fetching metadata: $metaUri');
          }
          final metaFile = File(p.join(stagingDir.path, manifest.metadataPath!));
          await metaFile.parent.create(recursive: true);
          await metaFile.writeAsBytes(resp.bodyBytes);
        }

        if (manifest.strokesPath != null) {
          final strokeUri = manifestUri.resolve(manifest.strokesPath!);
          final resp = await _fetchWithRetry(strokeUri, options);
          if (resp.statusCode != HttpStatus.ok) {
            throw HttpException('HTTP ${resp.statusCode} fetching strokes: $strokeUri');
          }
          final strokeFile = File(p.join(stagingDir.path, manifest.strokesPath!));
          await strokeFile.parent.create(recursive: true);
          await strokeFile.writeAsBytes(resp.bodyBytes);
        }

        if (manifest.audioPath != null) {
          // Check for audio files list in manifest or audio index
          final rawAudioFiles = jsonMap['audioFiles'] ?? jsonMap['audio_files'];
          if (rawAudioFiles is List) {
            for (final item in rawAudioFiles) {
              final audioFileRel = item.toString();
              final audioUri = manifestUri.resolve(audioFileRel);
              final resp = await _fetchWithRetry(audioUri, options);
              if (resp.statusCode == HttpStatus.ok) {
                final audioFile = File(p.join(stagingDir.path, audioFileRel));
                await audioFile.parent.create(recursive: true);
                await audioFile.writeAsBytes(resp.bodyBytes);
              }
            }
          }
        }
      }

      // 5. Deep validation
      final valRes = await _validator.validatePackageDirectory(
        stagingDir,
        explicitManifest: manifest,
      );
      if (!valRes.isSuccess) {
        await _stagingManager.purgeStagingDirectory(stagingDir);
        return valRes;
      }

      // 6. Promotion
      final promotedDir = await _stagingManager.promoteStagedPackage(
        stagingDir: stagingDir,
        packageId: manifest.id,
      );

      return IngestionResult.success(
        manifest: manifest,
        packageDirectory: promotedDir.path,
      );
    } on TimeoutException {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return const IngestionResult.failure(
        errorCode: IngestionErrorCode.timeout,
        errorMessage: 'Network timeout downloading remote package contents.',
      );
    } catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.networkError,
        errorMessage: 'Failed downloading and staging remote package: $e',
      );
    }
  }

  /// Internal helper to execute HTTP GET with exponential retry on 5xx errors.
  Future<_HttpResponse> _fetchWithRetry(Uri uri, FetchOptions options) async {
    int attempts = 0;
    while (true) {
      attempts++;
      try {
        final request = await _client.getUrl(uri).timeout(options.connectTimeout);
        if (options.headers != null) {
          options.headers!.forEach((k, v) => request.headers.set(k, v));
        }

        final response = await request.close().timeout(options.receiveTimeout);
        final statusCode = response.statusCode;

        // Collect body bytes with size limit guard
        final bytesBuilder = BytesBuilder(copy: false);
        var totalBytes = 0;

        await for (final chunk in response.timeout(options.receiveTimeout)) {
          totalBytes += chunk.length;
          if (totalBytes > options.maxPackageSizeBytes) {
            await response.detachSocket();
            throw SecurityException('Response payload exceeded maximum allowed limit of ${options.maxPackageSizeBytes} bytes.');
          }
          bytesBuilder.add(chunk);
        }

        final bodyBytes = bytesBuilder.takeBytes();

        // If 5xx and we have retries left, delay and retry
        if (statusCode >= 500 && statusCode < 600 && attempts <= options.maxRetries) {
          final backoff = options.retryDelay * (1 << (attempts - 1));
          await Future<void>.delayed(backoff);
          continue;
        }

        return _HttpResponse(statusCode: statusCode, bodyBytes: bodyBytes);
      } on SocketException catch (_) {
        if (attempts <= options.maxRetries) {
          final backoff = options.retryDelay * (1 << (attempts - 1));
          await Future<void>.delayed(backoff);
          continue;
        }
        rethrow;
      }
    }
  }
}

class _HttpResponse {
  final int statusCode;
  final List<int> bodyBytes;

  const _HttpResponse({required this.statusCode, required this.bodyBytes});

  String get bodyString => utf8.decode(bodyBytes, allowMalformed: true);
}
