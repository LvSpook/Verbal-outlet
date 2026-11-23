/// Word-level text preparation used by the note search.
///
/// Kept separate from the engine so the matching rules stay readable: this file
/// only knows how to cut text into words and reduce those words to a stem.
library;

/// One word in a piece of text, with where it sits in the original string.
class Token {
  const Token({
    required this.text,
    required this.normal,
    required this.stem,
    required this.start,
    required this.end,
  });

  /// The word as written.
  final String text;

  /// Lower-cased, apostrophes removed. Used for exact comparisons.
  final String normal;

  /// A crude root form, so "walking", "walked" and "walks" all compare equal.
  final String stem;

  /// Character range in the source text, for highlighting.
  final int start;
  final int end;
}

/// A word: letters or digits, with an internal apostrophe allowed so "don't"
/// stays one word rather than becoming "don" and "t".
final RegExp _wordPattern = RegExp(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)*");

String _normalizeWord(String word) =>
    word.toLowerCase().replaceAll(RegExp(r"['’]"), '');

/// Splits [text] into tokens, keeping their positions.
List<Token> tokenize(String text) {
  final tokens = <Token>[];
  for (final match in _wordPattern.allMatches(text)) {
    final raw = match.group(0)!;
    final normal = _normalizeWord(raw);
    if (normal.isEmpty) continue;
    tokens.add(
      Token(
        text: raw,
        normal: normal,
        stem: stem(normal),
        start: match.start,
        end: match.end,
      ),
    );
  }
  return tokens;
}

/// Folds a word towards a root form.
///
/// This is deliberately a small set of English suffix rules rather than a full
/// Porter stemmer: notes are short and conversational, and the point is only to
/// stop "book"/"booking"/"booked" from being treated as different ideas. Cases
/// it cannot handle (irregular verbs like "swam") are covered by the synonym
/// list instead.
String stem(String word) {
  if (word.length <= 3) return word;
  // Purely numeric tokens keep their form: "2024" must not lose a digit.
  if (RegExp(r'^[0-9]+$').hasMatch(word)) return word;

  var s = word;

  if (s.endsWith('ies') && s.length > 4) {
    s = '${s.substring(0, s.length - 3)}y';
  } else if (s.endsWith('sses') ||
      s.endsWith('xes') ||
      s.endsWith('ches') ||
      s.endsWith('shes') ||
      s.endsWith('zes')) {
    s = s.substring(0, s.length - 2);
  } else if (s.endsWith('s') &&
      !s.endsWith('ss') &&
      !s.endsWith('us') &&
      !s.endsWith('is')) {
    s = s.substring(0, s.length - 1);
  }

  if (s.endsWith('ing') && s.length > 5) {
    s = _undouble(s.substring(0, s.length - 3));
  } else if (s.endsWith('edly') && s.length > 6) {
    s = _undouble(s.substring(0, s.length - 4));
  } else if (s.endsWith('ed') && s.length > 4) {
    s = _undouble(s.substring(0, s.length - 2));
  } else if (s.endsWith('ly') && s.length > 5) {
    s = s.substring(0, s.length - 2);
  } else if (s.endsWith('ness') && s.length > 6) {
    s = s.substring(0, s.length - 4);
  } else if (s.endsWith('ment') && s.length > 6) {
    s = s.substring(0, s.length - 4);
  }

  // "tire"/"tired" both land on "tir" this way.
  if (s.endsWith('e') && s.length > 3) s = s.substring(0, s.length - 1);

  // Never stem away to nothing useful.
  if (s.length < 3) return word;
  return s;
}

/// Drops a doubled final consonant left behind by removing a suffix:
/// "swimm" -> "swim", but "fall" and "pass" are left alone.
String _undouble(String s) {
  if (s.length < 3) return s;
  final last = s[s.length - 1];
  if (last == s[s.length - 2] && !'lsz'.contains(last)) {
    return s.substring(0, s.length - 1);
  }
  return s;
}

/// Words too common to carry meaning on their own.
const Set<String> stopwords = {
  'a',
  'about',
  'after',
  'again',
  'all',
  'also',
  'am',
  'an',
  'and',
  'any',
  'are',
  'as',
  'at',
  'be',
  'because',
  'been',
  'before',
  'being',
  'both',
  'but',
  'by',
  'can',
  'cant',
  'could',
  'did',
  'didnt',
  'do',
  'does',
  'doesnt',
  'doing',
  'dont',
  'down',
  'during',
  'each',
  'few',
  'for',
  'from',
  'further',
  'had',
  'hadnt',
  'has',
  'hasnt',
  'have',
  'havent',
  'having',
  'he',
  'her',
  'here',
  'hers',
  'herself',
  'him',
  'himself',
  'his',
  'how',
  'i',
  'if',
  'im',
  'in',
  'into',
  'is',
  'isnt',
  'it',
  'its',
  'itself',
  'just',
  'me',
  'more',
  'most',
  'my',
  'myself',
  'no',
  'nor',
  'not',
  'now',
  'of',
  'off',
  'on',
  'once',
  'only',
  'or',
  'other',
  'ought',
  'our',
  'ours',
  'ourselves',
  'out',
  'over',
  'own',
  'same',
  'she',
  'should',
  'shouldnt',
  'so',
  'some',
  'such',
  'than',
  'that',
  'thats',
  'the',
  'their',
  'theirs',
  'them',
  'themselves',
  'then',
  'there',
  'these',
  'they',
  'this',
  'those',
  'through',
  'to',
  'too',
  'under',
  'until',
  'up',
  'very',
  'was',
  'wasnt',
  'we',
  'were',
  'werent',
  'what',
  'when',
  'where',
  'which',
  'while',
  'who',
  'whom',
  'why',
  'will',
  'with',
  'wont',
  'would',
  'wouldnt',
  'you',
  'your',
  'youre',
  'yours',
  'yourself',
  'yourselves',
};

bool isStopword(String normal) => stopwords.contains(normal);

/// Edit distance between two short words, giving up once it exceeds [limit].
///
/// Used for typo tolerance, so it only needs to be exact at small distances.
int editDistance(String a, String b, {int limit = 3}) {
  if (a == b) return 0;
  if ((a.length - b.length).abs() > limit) return limit + 1;

  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);

  for (var i = 0; i < a.length; i++) {
    current[0] = i + 1;
    var rowMin = current[0];
    for (var j = 0; j < b.length; j++) {
      final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      final deletion = previous[j + 1] + 1;
      final insertion = current[j] + 1;
      final substitution = previous[j] + cost;
      var best = deletion < insertion ? deletion : insertion;
      if (substitution < best) best = substitution;
      current[j + 1] = best;
      if (best < rowMin) rowMin = best;
    }
    if (rowMin > limit) return limit + 1;
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}
