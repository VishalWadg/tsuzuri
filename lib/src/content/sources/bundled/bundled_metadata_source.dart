import '../../../data/content_db.dart';
import '../../contracts/kanji_metadata_source.dart';

/// Zero-configuration bundled metadata adapter wrapping read-only [ContentDatabase].
class BundledMetadataSource implements IKanjiMetadataSource {
  static const String defaultSourceId = 'bundled_metadata';
  static const String defaultDisplayName = 'Bundled Kanji Metadata';

  final ContentDatabase _contentDb;
  final String _sourceId;
  final String _displayName;

  BundledMetadataSource({
    required ContentDatabase contentDb,
    String sourceId = defaultSourceId,
    String displayName = defaultDisplayName,
  })  : _contentDb = contentDb,
        _sourceId = sourceId,
        _displayName = displayName;

  ContentDatabase get contentDb => _contentDb;

  @override
  String get sourceId => _sourceId;

  @override
  String get displayName => _displayName;

  @override
  String get version => '${_contentDb.contentVersion}.0.0';

  @override
  bool get isBundledDefault => true;

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async {
    if (codepoint <= 0) return null;
    final kanji = _contentDb.getKanjiByCodepoint(codepoint);
    if (kanji == null) return null;
    return KanjiMetadataEntry.fromKanjiCharacter(kanji);
  }

  @override
  Future<List<int>> getAllCodepoints() async {
    return _contentDb.getOrderedCodepoints();
  }

  @override
  Future<int> getCharacterCount() async {
    return _contentDb.totalKanjiCount;
  }

  @override
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (count <= 0) return const [];
    return _contentDb.generateMeaningDistractors(
      target.toKanjiCharacter(),
      count: count,
    );
  }

  @override
  Future<List<String>> generateReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (count <= 0) return const [];
    return _contentDb.generateReadingDistractors(
      target.toKanjiCharacter(),
      count: count,
    );
  }
}
