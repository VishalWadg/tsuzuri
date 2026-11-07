import 'package:path/path.dart' as p;

/// Exception thrown when a security violation, path traversal, or archive bomb is detected.
class SecurityException implements Exception {
  final String message;
  const SecurityException(this.message);

  @override
  String toString() => 'SecurityException: $message';
}

/// 6-layer defense guard against Zip-Slip path traversal attacks, symbolic link exploits,
/// and archive bomb resource exhaustion.
class ZipSlipGuard {
  static const int maxEntryCount = 5000;
  static const int maxSingleFileSizeBytes = 50 * 1024 * 1024; // 50 MB
  static const int maxTotalPackageSizeBytes = 250 * 1024 * 1024; // 250 MB
  static const double maxCompressionRatio = 100.0;

  static final RegExp _windowsDriveRegex = RegExp(r'^[a-zA-Z]:');

  /// Resolves [entryName] against [destDir] and validates that the resulting file
  /// path resides strictly inside [destDir] through 6 defensive layers.
  ///
  /// Returns the fully verified normalized target path.
  /// Throws [SecurityException] on any violation.
  static String resolveAndVerifyEntry(
    String destDir,
    String entryName, {
    bool isSymbolicLink = false,
  }) {
    // ---------------------------------------------------------
    // Layer 1: Symlink & Null-Byte Gate
    // ---------------------------------------------------------
    if (isSymbolicLink) {
      throw SecurityException(
        'Archive entry "$entryName" is a symbolic link. Symlinks are strictly prohibited.',
      );
    }
    if (entryName.contains('\x00')) {
      throw SecurityException(
        'Archive entry "$entryName" contains null bytes.',
      );
    }

    // ---------------------------------------------------------
    // Layer 2: Fast-Path String Pattern Gate
    // ---------------------------------------------------------
    var sanitized = entryName.replaceAll('\\', '/');
    if (sanitized.isEmpty) {
      throw const SecurityException('Archive entry name cannot be empty.');
    }

    // Strip leading './' if present (some archivers prepend ./)
    while (sanitized.startsWith('./')) {
      sanitized = sanitized.substring(2);
    }

    if (sanitized.isEmpty) {
      throw const SecurityException('Archive entry name cannot be empty or root reference.');
    }

    // Absolute POSIX or Windows drive / UNC paths
    if (sanitized.startsWith('/') ||
        sanitized.startsWith('//') ||
        _windowsDriveRegex.hasMatch(sanitized)) {
      throw SecurityException(
        'Archive entry "$entryName" specifies an absolute or drive path.',
      );
    }

    final segments = sanitized.split('/');
    for (final segment in segments) {
      if (segment == '..' || segment == '.') {
        throw SecurityException(
          'Archive entry "$entryName" contains illegal directory traversal segment ("$segment").',
        );
      }
    }

    // ---------------------------------------------------------
    // Layer 3 & 4: Normalized Boundary & Trailing Separator Check
    // ---------------------------------------------------------
    final destNorm = p.normalize(p.absolute(destDir));
    final targetNorm = p.normalize(p.join(destNorm, sanitized));

    final destWithSep = destNorm.endsWith(p.separator)
        ? destNorm
        : '$destNorm${p.separator}';

    if (!targetNorm.startsWith(destWithSep) || !p.isWithin(destNorm, targetNorm)) {
      throw SecurityException(
        'Archive entry "$entryName" escaped destination sandbox: target "$targetNorm" is not within "$destNorm".',
      );
    }

    // ---------------------------------------------------------
    // Layer 5: Canonicalization Equality Check (Windows Case & Drive Letter)
    // ---------------------------------------------------------
    final destCanon = p.canonicalize(destNorm);
    final targetCanon = p.canonicalize(targetNorm);
    final destCanonWithSep = destCanon.endsWith(p.separator)
        ? destCanon
        : '$destCanon${p.separator}';

    if (!targetCanon.startsWith(destCanonWithSep) || !p.isWithin(destCanon, targetCanon)) {
      throw SecurityException(
        'Archive entry "$entryName" canonical path "$targetCanon" escapes "$destCanon".',
      );
    }

    return targetNorm;
  }

  /// Returns true if [entryName] is safely resolvable within [destDir], false otherwise.
  static bool isPathSafe(
    String destDir,
    String entryName, {
    bool isSymbolicLink = false,
  }) {
    try {
      resolveAndVerifyEntry(destDir, entryName, isSymbolicLink: isSymbolicLink);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Layer 6: Verifies archive resource boundaries against zip bombs and decompression exhaustion.
  static void verifyResourceLimits({
    required int entryCount,
    required int totalUncompressedBytes,
    int? singleFileBytes,
    int? compressedBytes,
  }) {
    if (entryCount > maxEntryCount) {
      throw SecurityException(
        'Archive contains $entryCount entries, exceeding maximum allowed limit of $maxEntryCount.',
      );
    }

    if (totalUncompressedBytes > maxTotalPackageSizeBytes) {
      throw SecurityException(
        'Archive uncompressed size ($totalUncompressedBytes bytes) exceeds maximum limit of $maxTotalPackageSizeBytes bytes.',
      );
    }

    if (singleFileBytes != null && singleFileBytes > maxSingleFileSizeBytes) {
      throw SecurityException(
        'Archive entry size ($singleFileBytes bytes) exceeds single-file limit of $maxSingleFileSizeBytes bytes.',
      );
    }

    if (compressedBytes != null && compressedBytes > 0) {
      final ratio = totalUncompressedBytes / compressedBytes;
      if (ratio > maxCompressionRatio && totalUncompressedBytes > 1024 * 1024) {
        throw SecurityException(
          'Archive compression ratio ($ratio) exceeds safety threshold of $maxCompressionRatio.',
        );
      }
    }
  }
}
