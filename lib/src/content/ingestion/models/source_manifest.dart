/// Capabilities that a content source package can provide.
enum SourceCapability {
  metadata,
  strokes,
  audio;

  static SourceCapability? fromString(String value) {
    switch (value.trim().toLowerCase()) {
      case 'metadata':
      case 'providesmetadata':
        return SourceCapability.metadata;
      case 'strokes':
      case 'providesstrokes':
        return SourceCapability.strokes;
      case 'audio':
      case 'providesaudio':
        return SourceCapability.audio;
      default:
        return null;
    }
  }
}

/// Manifest specification for an offline or online content package.
class SourceManifest {
  /// Format version of the manifest file.
  final int formatVersion;

  /// Unique alphanumeric slug identifier (e.g. `jlpt_n5_expansion`).
  final String id;

  /// Human-readable title of the package.
  final String name;

  /// Semantic version (SemVer 2.0.0) of the package.
  final String version;

  /// Author or organization publishing the package.
  final String? author;

  /// Description of the package contents.
  final String? description;

  /// Set of capabilities provided by this package.
  final Set<SourceCapability> capabilities;

  /// Relative path inside the package directory to the metadata JSON file.
  final String? metadataPath;

  /// Relative path inside the package directory to the stroke vectors file/dir.
  final String? strokesPath;

  /// Relative path inside the package directory to the audio directory.
  final String? audioPath;

  /// Optional map of relative file paths to their expected checksums (e.g. `sha256:<hex>`).
  final Map<String, String>? checksums;

  const SourceManifest({
    this.formatVersion = 1,
    required this.id,
    required this.name,
    required this.version,
    this.author,
    this.description,
    required this.capabilities,
    this.metadataPath,
    this.strokesPath,
    this.audioPath,
    this.checksums,
  });

  /// Regular expression for validating source identifiers.
  static final RegExp _idRegex = RegExp(r'^[a-z0-9]+([._-][a-z0-9]+)*$');

  /// Regular expression strictly implementing Semantic Versioning 2.0.0.
  static final RegExp _semVerRegex = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)'
    r'(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?'
    r'(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$',
  );

  /// Validates whether [id] is a valid package identifier.
  static bool isValidId(String id) {
    if (id.isEmpty || id.length > 128) return false;
    return _idRegex.hasMatch(id);
  }

  /// Validates whether [version] complies with SemVer 2.0.0.
  static bool isValidSemVer(String version) {
    if (version.isEmpty) return false;
    return _semVerRegex.hasMatch(version);
  }

  /// Parses and validates a [SourceManifest] from a JSON map.
  /// Throws [FormatException] if validation fails.
  factory SourceManifest.fromJson(Map<String, dynamic> json) {
    // 1. Format version
    final fmt = json['formatVersion'] as int? ?? json['format_version'] as int? ?? 1;
    if (fmt != 1) {
      throw FormatException('Unsupported formatVersion: $fmt. Supported version is 1.');
    }

    // 2. Identifier
    final rawId = json['id'];
    if (rawId == null || rawId is! String || rawId.trim().isEmpty) {
      throw const FormatException('Missing required field: id');
    }
    final id = rawId.trim();
    if (!isValidId(id)) {
      throw FormatException(
        'Invalid source id: "$id". Must contain only lowercase alphanumeric characters, dots, underscores, or dashes.',
      );
    }

    // 3. Name
    final rawName = json['name'];
    if (rawName == null || rawName is! String || rawName.trim().isEmpty) {
      throw const FormatException('Missing required field: name');
    }
    final name = rawName.trim();

    // 4. Version
    final rawVersion = json['version'];
    if (rawVersion == null || rawVersion is! String || rawVersion.trim().isEmpty) {
      throw const FormatException('Missing required field: version');
    }
    final version = rawVersion.trim();
    if (!isValidSemVer(version)) {
      throw FormatException(
        'Invalid semver version: "$version". Must conform strictly to SemVer 2.0.0.',
      );
    }

    // 5. Capabilities
    final caps = <SourceCapability>{};
    final rawCaps = json['capabilities'];
    if (rawCaps is List) {
      for (final item in rawCaps) {
        final parsed = SourceCapability.fromString(item.toString());
        if (parsed != null) {
          caps.add(parsed);
        } else {
          throw FormatException('Unrecognized capability: "$item"');
        }
      }
    } else if (rawCaps is Map) {
      final map = rawCaps.cast<String, dynamic>();
      for (final entry in map.entries) {
        if (entry.value == true) {
          final parsed = SourceCapability.fromString(entry.key);
          if (parsed != null) {
            caps.add(parsed);
          }
        }
      }
    } else if (json['providesMetadata'] == true ||
        json['providesStrokes'] == true ||
        json['providesAudio'] == true) {
      if (json['providesMetadata'] == true) caps.add(SourceCapability.metadata);
      if (json['providesStrokes'] == true) caps.add(SourceCapability.strokes);
      if (json['providesAudio'] == true) caps.add(SourceCapability.audio);
    }

    if (caps.isEmpty) {
      throw const FormatException('Manifest must declare at least one capability.');
    }

    // Paths
    final pathsMap = json['paths'] is Map ? (json['paths'] as Map).cast<String, dynamic>() : null;
    final metadataPath = (json['metadataPath'] ?? json['metadata_path'] ?? pathsMap?['metadata']) as String?;
    final strokesPath = (json['strokesPath'] ?? json['strokes_path'] ?? pathsMap?['strokes']) as String?;
    final audioPath = (json['audioPath'] ?? json['audio_path'] ?? pathsMap?['audio']) as String?;

    // Checksums
    Map<String, String>? checksums;
    if (json['checksums'] is Map) {
      checksums = (json['checksums'] as Map).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }

    return SourceManifest(
      formatVersion: fmt,
      id: id,
      name: name,
      version: version,
      author: (json['author'] as String?)?.trim(),
      description: (json['description'] as String?)?.trim(),
      capabilities: Set.unmodifiable(caps),
      metadataPath: metadataPath?.trim(),
      strokesPath: strokesPath?.trim(),
      audioPath: audioPath?.trim(),
      checksums: checksums != null ? Map.unmodifiable(checksums) : null,
    );
  }

  /// Converts this manifest to a standard JSON map.
  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'id': id,
        'name': name,
        'version': version,
        if (author != null) 'author': author,
        if (description != null) 'description': description,
        'capabilities': capabilities.map((c) => c.name).toList(),
        if (metadataPath != null) 'metadataPath': metadataPath,
        if (strokesPath != null) 'strokesPath': strokesPath,
        if (audioPath != null) 'audioPath': audioPath,
        if (checksums != null) 'checksums': checksums,
      };

  SourceManifest copyWith({
    int? formatVersion,
    String? id,
    String? name,
    String? version,
    String? author,
    String? description,
    Set<SourceCapability>? capabilities,
    String? metadataPath,
    String? strokesPath,
    String? audioPath,
    Map<String, String>? checksums,
  }) {
    return SourceManifest(
      formatVersion: formatVersion ?? this.formatVersion,
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      author: author ?? this.author,
      description: description ?? this.description,
      capabilities: capabilities ?? this.capabilities,
      metadataPath: metadataPath ?? this.metadataPath,
      strokesPath: strokesPath ?? this.strokesPath,
      audioPath: audioPath ?? this.audioPath,
      checksums: checksums ?? this.checksums,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceManifest &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          version == other.version;

  @override
  int get hashCode => Object.hash(id, version);

  @override
  String toString() => 'SourceManifest(id: $id, name: $name, version: $version, capabilities: $capabilities)';
}
