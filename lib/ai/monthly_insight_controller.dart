/// Keeping a month's overview current without spending a model call every time
/// the calendar is drawn.
///
/// Two facts make this cheap. The overview depends only on the month's notes,
/// and those notes change rarely; so the notes are fingerprinted, and a stored
/// overview is reused while the fingerprint matches. Switching months is then
/// a cache read, and the one model call happens the first time a month is seen
/// (or after it is edited).
///
/// A failure is never shown as an error the person must fix. A previous
/// overview stays on screen if there is one, and otherwise the card simply does
/// not appear. Months with no notes ask the AI for nothing at all.
library;

import 'package:flutter/foundation.dart';

import '../data/note_store.dart';
import '../models/day_note.dart';
import 'ai_controller.dart';
import 'ai_provider.dart';
import 'monthly_insight.dart';

/// The state of one month's overview, as the card needs it.
class MonthlyInsightState {
  const MonthlyInsightState({
    this.insight,
    this.loading = false,
    this.generating = false,
    this.empty = false,
    this.error,
    this.revision = '',
  });

  /// The overview to show, cached or freshly generated.
  final MonthlyInsight? insight;

  /// True while the cache is being read.
  final bool loading;

  /// True while the AI is writing.
  final bool generating;

  /// True when the month has nothing written in it.
  final bool empty;

  /// A plain-language reason the overview could not be written, when there is
  /// one worth showing beside a stale overview.
  final String? error;

  /// The notes fingerprint the overview (or the attempt) was made from.
  final String revision;

  bool get hasContent => insight != null;

  /// Whether the shown overview no longer matches the notes.
  bool get stale => insight != null && insight!.isStaleFor(revision);

  MonthlyInsightState copyWith({
    MonthlyInsight? insight,
    bool? loading,
    bool? generating,
    bool? empty,
    String? error,
    String? revision,
    bool clearError = false,
  }) {
    return MonthlyInsightState(
      insight: insight ?? this.insight,
      loading: loading ?? this.loading,
      generating: generating ?? this.generating,
      empty: empty ?? this.empty,
      error: clearError ? null : (error ?? this.error),
      revision: revision ?? this.revision,
    );
  }
}

/// Loads, generates and caches the overview for one month at a time.
class MonthlyInsightController extends ChangeNotifier {
  MonthlyInsightController({
    required this.store,
    required this.ai,
    MonthlyInsightStore? cache,
  }) : _cache = cache ?? MonthlyInsightStore();

  final NoteStore store;
  final AiController ai;
  final MonthlyInsightStore _cache;

  int? _year;
  int? _month;
  MonthlyInsightState _state = const MonthlyInsightState(loading: true);
  bool _disposed = false;

  /// The month currently being shown, or null before the first load.
  int? get year => _year;
  int? get month => _month;
  MonthlyInsightState get state => _state;

  /// Points the controller at [year]/[month], reading the cache and generating
  /// only if needed.
  Future<void> show(int year, int month) async {
    if (_year == year && _month == month && !_state.loading) return;

    _year = year;
    _month = month;
    _state = const MonthlyInsightState(loading: true);
    _notify();

    final notes = _notesFor(year, month);
    if (notes.isEmpty) {
      _state = const MonthlyInsightState(empty: true);
      _notify();
      return;
    }

    final revision = revisionOf(notes);
    final cached = await _cache.read(year, month);
    if (_disposed || _year != year || _month != month) return;

    if (cached != null && !cached.isStaleFor(revision)) {
      _state = MonthlyInsightState(insight: cached, revision: revision);
      _notify();
      return;
    }

    // Show the old overview while the new one is written, so the card does not
    // blink out when a thought is added.
    _state = MonthlyInsightState(
      insight: cached,
      generating: true,
      revision: revision,
    );
    _notify();
    await _generate(year, month, notes, revision);
  }

  /// Re-reads the current month, e.g. after an entry changes.
  Future<void> refresh() async {
    final year = _year;
    final month = _month;
    if (year == null || month == null) return;
    // Force a fresh pass rather than short-circuiting on the same month.
    _year = null;
    _month = null;
    await show(year, month);
  }

  /// Asks for the overview again, even if the cache looks current.
  Future<void> regenerate() async {
    final year = _year;
    final month = _month;
    if (year == null || month == null) return;
    final notes = _notesFor(year, month);
    if (notes.isEmpty) {
      _state = const MonthlyInsightState(empty: true);
      _notify();
      return;
    }
    await _generate(year, month, notes, revisionOf(notes));
  }

  Future<void> _generate(
    int year,
    int month,
    List<DayNote> notes,
    String revision,
  ) async {
    if (_disposed) return;
    _state = _state.copyWith(generating: true, clearError: true);
    _notify();

    try {
      // Ask what composing asks: is there a model to talk to at all? Without
      // this, a laptop with Ollama closed would wait on a connection timeout
      // every time a month is opened, and the card would sit spinning.
      if (!await ai.canCompose()) {
        if (_disposed) return;
        _state = _state.copyWith(
          generating: false,
          error: 'The AI is not reachable, so no overview was written yet.',
        );
        _notify();
        return;
      }
      if (_disposed || _year != year || _month != month) return;

      final body = await ai.monthlyInsight(
        year: year,
        month: month,
        notes: notesToPromptText(notes),
      );
      if (_disposed || _year != year || _month != month) return;

      final insight = MonthlyInsight(
        year: year,
        month: month,
        body: body,
        generatedAt: DateTime.now(),
        revision: revision,
      );
      await _cache.write(insight);
      if (_disposed) return;
      _state = MonthlyInsightState(insight: insight, revision: revision);
      _notify();
    } on AiException catch (error) {
      if (_disposed) return;
      _state = _state.copyWith(generating: false, error: error.message);
      _notify();
    } catch (error) {
      if (_disposed) return;
      _state = _state.copyWith(
        generating: false,
        error: 'The overview could not be written: $error',
      );
      _notify();
    }
  }

  List<DayNote> _notesFor(int year, int month) => [
    for (final note in store.allNotes)
      if (note.day.year == year && note.day.month == month && note.isNotEmpty)
        note,
  ];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A fingerprint of a month's notes, for deciding whether an overview is stale.
///
/// Built from the day, the entry's identity, its last change, and its words.
/// The words are included on purpose: a single edit can land inside the same
/// millisecond as the previous one (or the clock can be adjusted backwards), and
/// a timestamp-only fingerprint would then say nothing had changed.
String revisionOf(List<DayNote> notes) {
  final parts = <String>[];
  for (final note in notes) {
    for (final section in note.visible) {
      parts.add(
        '${note.day.millisecondsSinceEpoch}:'
        '${section.id}:'
        '${section.modifiedAt.millisecondsSinceEpoch}:'
        '${section.content}',
      );
    }
  }
  return '${parts.length}:${parts.join('|').hashCode}';
}
