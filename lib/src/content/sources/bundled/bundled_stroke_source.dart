import '../../../data/content_db.dart';
import '../../../matching/stroke_matcher.dart';
import '../../contracts/kanji_stroke_source.dart';

/// Zero-configuration bundled stroke adapter wrapping read-only [ContentDatabase] KanjiVG vectors.
class BundledStrokeSource implements IKanjiStrokeSource {
  static const String defaultSourceId = 'bundled_strokes';
  static const String defaultDisplayName = 'Bundled KanjiVG Strokes';

  final ContentDatabase _contentDb;
  final String _sourceId;
  final String _displayName;

  BundledStrokeSource({
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
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) async {
    if (codepoint <= 0) return null;
    final kanji = _contentDb.getKanjiByCodepoint(codepoint);
    if (kanji == null || kanji.strokes.isEmpty) return null;
    return kanji.strokes;
  }

  @override
  Future<bool> containsStrokes(int codepoint) async {
    if (codepoint <= 0) return false;
    final kanji = _contentDb.getKanjiByCodepoint(codepoint);
    return kanji != null && kanji.strokes.isNotEmpty;
  }
}
