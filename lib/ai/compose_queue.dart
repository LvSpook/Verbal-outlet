/// The desk where a spoken thought becomes a diary entry.
///
/// Adding to a note no longer writes text straight into it. The words are
/// *held* ([ComposeState.pending]) and this queue asks the AI to turn them into
/// the entry the person reads back. The note itself only ever shows the result,
/// so a half-processed day never appears.
///
/// Two rules shape everything here:
///
/// * **Nothing is lost.** The original words are stored before the AI is asked.
///   A failure leaves them in place, marked failed, ready to retry.
/// * **No busy-loops against a dead model.** One attempt per entry per pass; if
///   the AI cannot answer, the pass stops instead of failing every entry in a
///   row. The next trigger (a new entry, opening the app, the retry button)
///   starts it again.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_settings.dart';
import '../data/note_store.dart';
import '../models/day_note.dart';

/// What happened when one entry was composed.
enum ComposeOutcome {
  /// The AI wrote it. The body is now in the store.
  written,

  /// The AI could not be reached, so the entry is still waiting.
  unavailable,

  /// The AI answered with an error. The entry is marked failed.
  failed,
}

/// Runs pending entries through the AI, one at a time.
class ComposeQueue extends ChangeNotifier {
  ComposeQueue({
    required this.store,
    required this.ai,
    this.retryAfter = const Duration(seconds: 20),
  });

  final NoteStore store;
  final AiController ai;

  /// How long to wait before trying again while entries are held.
  ///
  /// The AI can become available with no event in the app at all - someone
  /// simply starts Ollama - so there is nothing to listen for. A slow poll is
  /// the honest mechanism. It only runs while something is waiting, and it
  /// doubles up to [_maxRetryAfter] so a laptop left open overnight is not
  /// asking a dead model every twenty seconds.
  final Duration retryAfter;

  static const Duration _maxRetryAfter = Duration(minutes: 2);

  Duration _currentRetry = Duration.zero;
  Timer? _retryTimer;
  bool _disposed = false;

  /// How long until the next quiet attempt, for a test to read. Zero when
  /// nothing is scheduled.
  @visibleForTesting
  Duration get nextRetryIn => _currentRetry;

  bool _running = false;

  /// True while a pass is working through entries, for the UI to show a spinner
  /// rather than pretend the note is finished.
  bool get busy => _running;

  /// How many entries are waiting, including failed ones.
  int get waiting => store.pendingCompositions.length;

  /// True when there is something to write and the queue is not already on it.
  bool get hasWork => store.pendingCompositions.isNotEmpty;

  /// The last thing that went wrong with the AI, for a quiet banner. Cleared as
  /// soon as a pass succeeds.
  String? _blockedReason;
  String? get blockedReason => _blockedReason;

  /// Starts a pass if one is not already running.
  ///
  /// Safe to call often: a new entry, returning to the app, pressing retry. It
  /// does nothing when there is no work, which is the common case.
  Future<void> kick() async {
    if (_running || !hasWork) return;
    await _drain();
  }

  /// Runs every waiting entry through the AI once.
  ///
  /// [fromTimer] is true for the quiet background attempt, which must keep the
  /// backoff it was scheduled with; a kick from the person or a new entry starts
  /// the wait over.
  Future<void> _drain({bool fromTimer = false}) async {
    _running = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!fromTimer) _currentRetry = Duration.zero;
    notifyListeners();

    var held = false;
    try {
      // Checked once per pass rather than per entry: if the model is down, all
      // the entries would fail the same way, and N timeouts is a long silence.
      if (!await ai.canCompose()) {
        _blockedReason = ai.settings.engine == AiEngineKind.cloud
            ? 'The AI is not ready. Check your API key in AI settings.'
            : 'The AI is not ready. Start Ollama, or pick a model in AI '
                'settings.';
        held = true;
        return;
      }

      // A snapshot: composing one entry changes the store, and re-reading the
      // live list mid-pass would walk a moving target.
      final pending = store.pendingCompositions;
      for (final (day, section) in pending) {
        if (section.deleted) continue;
        final outcome = await compose(day, section);
        if (outcome == ComposeOutcome.unavailable) {
          held = true;
          return;
        }
      }
      _blockedReason = null;
    } finally {
      _running = false;
      if (!_disposed) {
        // Anything still waiting means the AI is not answering, so keep
        // checking quietly in the background until it does.
        if (held && hasWork) {
          _scheduleRetry();
        } else {
          _cancelRetry();
        }
      }
      notifyListeners();
    }
  }

  /// Arranges the next automatic attempt, backing off each time.
  ///
  /// The first retry is [retryAfter], then twice that, then twice again, capped
  /// at [_maxRetryAfter]. Any successful pass, or a manual kick, resets it.
  void _scheduleRetry() {
    _retryTimer?.cancel();

    final next = _currentRetry == Duration.zero
        ? retryAfter
        : _currentRetry * 2;
    _currentRetry = next > _maxRetryAfter ? _maxRetryAfter : next;

    _retryTimer = Timer(_currentRetry, () {
      _retryTimer = null;
      if (!_disposed) _drain(fromTimer: true);
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _currentRetry = Duration.zero;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRetry();
    super.dispose();
  }

  /// Composes one entry and writes the result into the store.
  ///
  /// Exposed so "try again" on a failed entry can go straight to one entry
  /// instead of a whole pass.
  Future<ComposeOutcome> compose(DateTime day, NoteSection section) async {
    try {
      final body = await ai.compose(
        text: section.text,
        instruction: section.instruction,
      );
      store.replaceSection(day, section.withBody(body));
      return ComposeOutcome.written;
    } on AiException catch (error) {
      // A provider that is simply not there should not mark the entry failed:
      // it will be written as soon as the model is back, which is the whole
      // point of holding it. A real answer from a real model is different.
      if (_looksUnavailable(error)) return ComposeOutcome.unavailable;
      store.replaceSection(day, section.withFailure(error.message));
      return ComposeOutcome.failed;
    } catch (error) {
      store.replaceSection(
        day,
        section.withFailure('Could not write this entry: $error'),
      );
      return ComposeOutcome.failed;
    }
  }

  /// Retries a single failed entry.
  Future<ComposeOutcome> retry(DateTime day, NoteSection section) async {
    final outcome = await compose(day, section);
    if (outcome == ComposeOutcome.written) _blockedReason = null;
    notifyListeners();
    return outcome;
  }

  /// Whether a failure means "the model is not there" rather than "the model
  /// answered badly".
  ///
  /// Kept deliberately narrow. These are the messages the providers use when
  /// they could not be reached at all. A rejected API key is *not* here: it is
  /// a real answer, and holding an entry forever because of a typo in a key
  /// would be worse than saying so. Network trouble on the cloud side is still
  /// caught, because that surfaces as "could not reach".
  static bool _looksUnavailable(AiException error) {
    final message = error.message.toLowerCase();
    return message.contains('could not reach') ||
        message.contains('not installed') ||
        message.contains('not running') ||
        message.contains('not available') ||
        message.contains('not downloaded') ||
        message.contains('timed out');
  }
}
