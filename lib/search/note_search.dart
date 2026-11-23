/// Smart search over a day's note.
///
/// The point is to find what you meant, not what you typed:
///
/// * **Word forms** — "walk" finds "walked" and "walking"; "book" finds
///   "booked".
/// * **Typos** — "exausted" still finds "exhausted", by edit distance.
/// * **Concepts** — "tired" finds "knackered", "money" finds "rent". See
///   `concepts.dart` for the vocabulary.
/// * **Phrases** — "need to" or "catch up" match as a run of adjacent words and
///   score higher than the same words scattered about.
/// * **Ranking** — every match contributes a score; sections are ordered by
///   score, then by recency, so the best answer is first even when several
///   sections match.
///
/// The engine is deliberately separate from the widgets, and behind
/// [NoteSearcher]. [LexicalSearcher] is the on-device implementation; a future
/// embedding-based or cloud ranker can implement the same interface without the
/// UI changing.
library;

import '../models/day_note.dart';
import 'concepts.dart';
import 'search_text.dart';

/// Why a stretch of text matched, which drives the highlight colour.
enum MatchKind { direct, stem, fuzzy, concept }

/// A section that matched a search across every note, with the day it belongs
/// to.
///
/// The single-day search does not need this: the day is the pane. A global
/// search does, because the result list mixes days and has to say which one a
/// hit came from.
class GlobalHit {
  const GlobalHit({required this.day, required this.hit});

  /// The note's day, at midnight.
  final DateTime day;

  final NoteHit hit;
}

/// A run of characters to emphasise, with offsets into the excerpt it belongs
/// to (not the original section text).
class MatchSpan {
  const MatchSpan(this.start, this.end, this.kind);

  final int start;
  final int end;
  final MatchKind kind;
}

/// One section that matched the query.
class NoteHit {
  const NoteHit({
    required this.section,
    required this.excerpt,
    required this.spans,
    required this.score,
    this.reasons = const [],
  });

  final NoteSection section;

  /// The text to show, trimmed around the first hit when the section is long.
  final String excerpt;

  /// Highlights, with offsets into [excerpt].
  final List<MatchSpan> spans;

  /// Higher is better. Only meaningful for ordering within one search.
  final double score;

  /// Plain-language notes about why this matched, e.g. "also matched
  /// 'exhausted'". Empty when the match was literal.
  final List<String> reasons;
}

/// A whole set of results for one query.
class NoteSearchResult {
  const NoteSearchResult({
    required this.query,
    required this.hits,
    this.interpretation,
  });

  final String query;
  final List<NoteHit> hits;

  /// A short explanation of how the query was read, when it was expanded in a
  /// non-obvious way. Null when the query was taken literally.
  final String? interpretation;

  bool get isEmpty => hits.isEmpty;
  bool get isNotEmpty => hits.isNotEmpty;
}

/// The result of searching every note at once.
class GlobalSearchResult {
  const GlobalSearchResult({
    required this.query,
    required this.hits,
    this.interpretation,
    this.daysSearched = 0,
  });

  final String query;

  /// Ranked across all days, best first.
  final List<GlobalHit> hits;

  final String? interpretation;

  /// How many non-empty notes were looked at, for the "searched N days" line.
  final int daysSearched;

  bool get isEmpty => hits.isEmpty;
  bool get isNotEmpty => hits.isNotEmpty;

  /// Distinct days that produced at least one hit.
  int get dayCount => {for (final hit in hits) hit.day}.length;
}

/// Anything that can turn a query plus a note into ranked hits.
///
/// Implement this to swap in a smarter backend later (for instance one that
/// embeds notes and ranks by vector similarity). The UI depends only on this.
abstract interface class NoteSearcher {
  /// Human-readable name, shown under the search field.
  String get engineName;

  NoteSearchResult search(DayNote note, String query);

  /// The same search across every note.
  ///
  /// Scores are comparable across days because the scoring rules are identical,
  /// so a single ranked list is meaningful: the best answer anywhere comes
  /// first, not the best answer per day.
  GlobalSearchResult searchAll(Iterable<DayNote> notes, String query);
}

/// Purely local, rule-based search. Fast enough to run on every keystroke.
class LexicalSearcher implements NoteSearcher {
  const LexicalSearcher();

  @override
  String get engineName => 'On-device';

  /// How much text to show either side of the first hit in a long section.
  static const int excerptRadius = 90;

  @override
  NoteSearchResult search(DayNote note, String query) {
    final rawQuery = query.trim();
    if (rawQuery.isEmpty) return NoteSearchResult(query: rawQuery, hits: []);

    final parsed = _parseQuery(rawQuery);
    if (parsed.terms.isEmpty) {
      return NoteSearchResult(query: rawQuery, hits: []);
    }

    final hits = <NoteHit>[];
    for (final section in note.sections) {
      final hit = _scoreSection(section, parsed);
      if (hit != null) hits.add(hit);
    }

    _sortHits(hits);

    return NoteSearchResult(
      query: rawQuery,
      hits: hits,
      interpretation: parsed.interpretation,
    );
  }

  @override
  GlobalSearchResult searchAll(Iterable<DayNote> notes, String query) {
    final rawQuery = query.trim();
    if (rawQuery.isEmpty) {
      return GlobalSearchResult(query: rawQuery, hits: []);
    }

    final parsed = _parseQuery(rawQuery);
    if (parsed.terms.isEmpty) {
      return GlobalSearchResult(query: rawQuery, hits: []);
    }

    var searched = 0;
    final hits = <GlobalHit>[];
    for (final note in notes) {
      if (note.isEmpty) continue;
      searched++;

      // The day is copied out of the note rather than taken from a section, so
      // a thought added today to a note from last week still reports the day it
      // was filed under, which is what the calendar will open.
      final day = DateTime(note.day.year, note.day.month, note.day.day);
      for (final section in note.sections) {
        final hit = _scoreSection(section, parsed);
        if (hit != null) hits.add(GlobalHit(day: day, hit: hit));
      }
    }

    hits.sort((a, b) {
      final byScore = b.hit.score.compareTo(a.hit.score);
      if (byScore != 0) return byScore;
      // Ties go to the more recent thought, then to the more recent day. Same
      // rule as the single-day search, so the ordering feels familiar.
      final byTime = b.hit.section.createdAt.compareTo(a.hit.section.createdAt);
      if (byTime != 0) return byTime;
      return b.day.compareTo(a.day);
    });

    return GlobalSearchResult(
      query: rawQuery,
      hits: hits,
      interpretation: parsed.interpretation,
      daysSearched: searched,
    );
  }

  /// Highest score first, then the more recent thought.
  void _sortHits(List<NoteHit> hits) {
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.section.createdAt.compareTo(a.section.createdAt);
    });
  }

  NoteHit? _scoreSection(NoteSection section, _ParsedQuery parsed) {
    final text = section.searchableText;
    final tokens = tokenize(text);
    if (tokens.isEmpty) return null;

    final spans = <(int, int, MatchKind)>[];
    final bestSpans = <(int, int)>[];
    var score = 0.0;

    // Every term has to be satisfied, so a two-word query narrows rather than
    // widens: "tired work" should not return every mention of work.
    for (final term in parsed.terms) {
      final matches = _matchesForTerm(term, tokens);
      if (matches.isEmpty) return null;

      // Score each term once, by its strongest match. Summing every occurrence
      // would let a section that repeats a related word outrank one that says
      // the thing you actually typed.
      score += matches.bestScore;
      spans.addAll(matches.spans);
      if (matches.bestSpan != null) bestSpans.add(matches.bestSpan!);
    }

    // Reward hits that sit close together: "tired after work" answers "tired
    // work" better than the same words on opposite sides of the note. Only
    // across different terms, never two matches of the same term.
    if (bestSpans.length > 1) score += _proximityBonus(bestSpans);

    final merged = _mergeSpans(spans);
    final (excerpt, excerptSpans) = _buildExcerpt(
      text,
      merged,
      excerptRadius,
    );

    return NoteHit(
      section: section,
      excerpt: excerpt,
      spans: excerptSpans,
      score: score,
      reasons: parsed.reasons,
    );
  }

  /// Bonus scaled by how tightly the best match of each term clusters.
  double _proximityBonus(List<(int, int)> spans) {
    final sorted = [...spans]..sort((a, b) => a.$1.compareTo(b.$1));
    var closest = 1 << 30;
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i].$1 - sorted[i - 1].$2;
      if (gap < closest) closest = gap;
    }
    if (closest <= 1) return 1.5;
    if (closest <= 24) return 1.2;
    if (closest <= 60) return 0.7;
    if (closest <= 140) return 0.3;
    return 0.0;
  }

  /// Finds one query term inside a section, by every rule in turn.
  ///
  /// Returns every occurrence, for highlighting, plus the strength of the best
  /// one, for ranking.
  _TermMatches _matchesForTerm(_QueryTerm term, List<Token> tokens) {
    final spans = <(int, int, MatchKind)>[];
    (int, int)? best;
    var bestScore = 0.0;

    void record(int start, int end, MatchKind kind, double weight) {
      spans.add((start, end, kind));
      if (weight > bestScore) {
        bestScore = weight;
        best = (start, end);
      }
    }

    // A single word matches on its own. A multi-word term must match as a run:
    // otherwise "caught up" would be satisfied by "caught" alone, which is a
    // different thing entirely.
    if (term.words.length == 1) {
      for (final token in tokens) {
        if (token.normal == term.normal) {
          record(token.start, token.end, MatchKind.direct, 4.0);
        } else if (term.stem.isNotEmpty && token.stem == term.stem) {
          record(token.start, token.end, MatchKind.stem, 2.6);
        } else if (term.conceptWords.contains(token.normal) ||
            term.conceptStems.contains(token.stem)) {
          record(token.start, token.end, MatchKind.concept, 1.8);
        }
      }
    }

    // Phrases: a run of adjacent words that together read as the query. A
    // phrase is the strongest evidence there is, so it outweighs any single
    // word match.
    if (term.words.length > 1) {
      for (var i = 0; i + term.words.length <= tokens.length; i++) {
        var ok = true;
        for (var w = 0; w < term.words.length; w++) {
          final token = tokens[i + w];
          final word = term.words[w];
          final matchesWord =
              token.normal == word ||
              token.stem == stem(word) ||
              term.conceptWords.contains(token.normal);
          if (!matchesWord) {
            ok = false;
            break;
          }
        }
        if (ok) {
          record(
            tokens[i].start,
            tokens[i + term.words.length - 1].end,
            MatchKind.direct,
            6.0,
          );
        }
      }
    }

    // Typos, only when nothing else matched and only for a single word: a
    // "closest word" guess at a phrase has no meaning.
    if (spans.isEmpty && term.words.length == 1 && term.normal.length >= 4) {
      final limit = term.normal.length >= 8 ? 2 : 1;
      for (final token in tokens) {
        if (token.normal.length < 4) continue;
        final distance = editDistance(term.normal, token.normal, limit: limit);
        if (distance > 0 && distance <= limit) {
          record(token.start, token.end, MatchKind.fuzzy, 1.0 / distance);
        }
      }
    }

    if (spans.isEmpty) return const _TermMatches.empty();
    return _TermMatches(spans: spans, bestScore: bestScore, bestSpan: best);
  }

  /// Reads the raw query into terms, expanding concepts once.
  _ParsedQuery _parseQuery(String raw) {
    // Quoted text is kept together as one phrase, and keeps its stopwords:
    // "caught up" and "sort out" stop making sense if "up" and "out" are
    // dropped.
    final quoted = RegExp(r'"([^"]+)"').firstMatch(raw);
    final free = raw.replaceAll(RegExp(r'"[^"]+"'), ' ');

    List<String> words(String text, {required bool dropStopwords}) =>
        tokenize(text)
            .map((t) => t.normal)
            .where((w) => w.isNotEmpty && (!dropStopwords || !isStopword(w)))
            .toList();

    final plain = words(free, dropStopwords: true);
    final phraseWords = quoted == null
        ? <String>[]
        : words(quoted.group(1)!, dropStopwords: false);

    final terms = <_QueryTerm>[];
    final explained = <String>{};

    void addTerm(List<String> termWords) {
      if (termWords.isEmpty) return;

      // Expand concepts: the searched word plus everything in its groups.
      final conceptWords = <String>{};
      final conceptStems = <String>{};
      for (final word in termWords) {
        for (final id in conceptsFor(word)) {
          for (final vocab in conceptVocabulary(id)) {
            conceptWords.add(vocab);
            conceptStems.add(stem(vocab));
          }
          explained.add(concepts[id].name);
        }
      }
      conceptWords.removeAll(termWords);

      terms.add(
        _QueryTerm(
          normal: termWords.join(),
          stem: termWords.length == 1 ? stem(termWords.first) : '',
          words: termWords,
          conceptWords: conceptWords,
          conceptStems: conceptStems,
        ),
      );
    }

    for (final word in plain) {
      addTerm([word]);
    }
    addTerm(phraseWords);

    final interpretation = explained.isEmpty
        ? null
        : 'Also looking for related wording: ${_joinNames(explained)}';

    return _ParsedQuery(
      terms: terms,
      reasons: explained.isEmpty
          ? const []
          : ['Related wording: ${_joinNames(explained)}'],
      interpretation: interpretation,
    );
  }

  /// Cuts a readable window of [text] around the first hit and maps the spans
  /// into that window's coordinates.
  ///
  /// The excerpt is whitespace-collapsed, which changes offsets, so a map from
  /// each excerpt position back to the source is built as the text is
  /// collapsed. That keeps every highlight exactly on the word it came from,
  /// instead of re-finding words by text and hoping they land in the right
  /// place.
  (String, List<MatchSpan>) _buildExcerpt(
    String text,
    List<(int, int, MatchKind)> spans,
    int radius,
  ) {
    if (spans.isEmpty) return (text, const []);

    final first = spans.first.$1;

    // Start a little before the first hit, snapped back to a word boundary.
    var from = first - radius;
    if (from > 0) {
      final space = text.lastIndexOf(RegExp(r'\s'), from);
      from = space < 0 ? 0 : space + 1;
    } else {
      from = 0;
    }

    // Take at least as much again after the last hit, so the sentence around
    // it is readable.
    var to = spans.last.$2 + radius;
    if (to < text.length) {
      final space = text.indexOf(RegExp(r'\s'), to);
      to = space < 0 ? text.length : space;
    } else {
      to = text.length;
    }
    if (to <= from) return (text, const []);

    // Collapse whitespace, remembering where every kept character came from.
    final buffer = StringBuffer();
    final origin = <int>[];
    var lastWasSpace = true;
    for (var i = from; i < to; i++) {
      final char = text[i];
      final isSpace =
          char == ' ' || char == '\n' || char == '\t' || char == '\r';
      if (isSpace) {
        if (!lastWasSpace) {
          buffer.write(' ');
          origin.add(i);
        }
        lastWasSpace = true;
      } else {
        buffer.write(char);
        origin.add(i);
        lastWasSpace = false;
      }
    }

    // Trim the leading and trailing space the collapse can leave behind.
    var start = 0;
    var end = origin.length;
    while (start < end && text[origin[start]] == ' ') {
      start++;
    }
    while (end > start && text[origin[end - 1]] == ' ') {
      end--;
    }

    final body = buffer.toString().substring(start, end);
    final prefix = from > 0 ? '…' : '';
    final suffix = to < text.length ? '…' : '';

    final shifted = <MatchSpan>[];
    for (final (spanStart, spanEnd, kind) in spans) {
      final lo = _excerptIndex(origin, spanStart, start, end);
      final hi = _excerptIndex(origin, spanEnd, start, end);
      if (lo == null || hi == null || hi <= lo) continue;
      // Merge overlaps against the last span, so a phrase and its words do not
      // paint twice.
      if (shifted.isNotEmpty && lo <= shifted.last.end) {
        final last = shifted.last;
        if (hi > last.end) {
          shifted[shifted.length - 1] = MatchSpan(last.start, hi, last.kind);
        }
        continue;
      }
      shifted.add(MatchSpan(lo + prefix.length, hi + prefix.length, kind));
    }

    return ('$prefix$body$suffix', shifted);
  }

  /// Position in the collapsed excerpt of source offset [sourceIndex].
  ///
  /// Returns null when the character was dropped (whitespace that got collapsed
  /// or trimmed), and clamps hits just outside [from, to) onto the nearest kept
  /// character so a match spanning the window edge still highlights.
  int? _excerptIndex(List<int> origin, int sourceIndex, int start, int end) {
    for (var i = start; i < end; i++) {
      if (origin[i] >= sourceIndex) return i - start;
    }
    // Past the end: clamp to the end of the excerpt if it is beyond it.
    if (origin.isNotEmpty && sourceIndex > origin[end - 1]) {
      return end - start;
    }
    return null;
  }
}

String _joinNames(Set<String> names) {
  final list = names.toList()..sort();
  if (list.length == 1) return '“${list.first}”';
  final head = list.sublist(0, list.length - 1).map((n) => '“$n”').join(', ');
  return '$head and “${list.last}”';
}

/// Overlapping or adjacent spans are merged so highlighting cannot double up.
List<(int, int, MatchKind)> _mergeSpans(List<(int, int, MatchKind)> spans) {
  if (spans.length <= 1) return spans;
  final sorted = [...spans]..sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int, MatchKind)>[sorted.first];
  for (final span in sorted.skip(1)) {
    final last = merged.last;
    if (span.$1 <= last.$2) {
      merged[merged.length - 1] = (
        last.$1,
        span.$2 > last.$2 ? span.$2 : last.$2,
        span.$3.index < last.$3.index ? last.$3 : span.$3,
      );
    } else {
      merged.add(span);
    }
  }
  return merged;
}

class _QueryTerm {
  const _QueryTerm({
    required this.normal,
    required this.stem,
    required this.words,
    required this.conceptWords,
    required this.conceptStems,
  });

  final String normal;
  final String stem;
  final List<String> words;
  final Set<String> conceptWords;
  final Set<String> conceptStems;
}

class _TermMatches {
  const _TermMatches({
    required this.spans,
    required this.bestScore,
    required this.bestSpan,
  });

  const _TermMatches.empty()
    : spans = const [],
      bestScore = 0.0,
      bestSpan = null;

  final List<(int, int, MatchKind)> spans;

  /// Strength of the strongest single occurrence of this term.
  final double bestScore;

  /// The strongest occurrence, for proximity scoring.
  final (int, int)? bestSpan;

  bool get isEmpty => spans.isEmpty;
}

class _ParsedQuery {
  const _ParsedQuery({
    required this.terms,
    required this.reasons,
    required this.interpretation,
  });

  final List<_QueryTerm> terms;
  final List<String> reasons;
  final String? interpretation;
}
