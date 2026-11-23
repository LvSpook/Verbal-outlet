/// The add-thought sheet: talk, watch the words arrive, then send it to the AI.
///
/// The shape follows the act. One big button starts listening; from then on the
/// transcript grows while you speak, a level bar shows the microphone is live,
/// and the AI may quietly ask a follow-up question when something in what you
/// said is worth pinning down. Answering it is just more talking — because the
/// live transcript is re-read from the start, the answer simply becomes part of
/// the entry.
///
/// Two other things happen here. If what you said was a request to the app
/// ("search my notes for the trip", "delete that last one"), it is carried out
/// instead of written down; anything destructive is confirmed first, aloud if
/// speech is on. And nothing is written into the note from this sheet: it hands
/// the words back, and the caller holds them for the AI, exactly like a typed
/// thought.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../ai/ai_controller.dart';
import '../../voice/speech_service.dart';
import '../../voice/voice_command.dart';
import '../../voice/voice_command_runner.dart';
import '../../voice/voice_controller.dart';
import '../../voice/voice_engine.dart';

/// What the person said, plus any instruction they gave.
class CapturedThought {
  const CapturedThought({required this.text, this.instruction = ''});

  final String text;
  final String instruction;
}

/// What the sheet decided to do with the person's words.
sealed class VoiceSheetResult {
  const VoiceSheetResult();
}

/// Words to turn into an entry.
class ThoughtResult extends VoiceSheetResult {
  const ThoughtResult(this.thought);
  final CapturedThought thought;
}

/// A command that has already been carried out, with the message to show.
class CommandResult extends VoiceSheetResult {
  const CommandResult(this.outcome);
  final CommandOutcome outcome;
}

/// Opens the sheet. Returns what to do with the words, or null if dismissed.
///
/// [ai] enables voice commands and follow-up questions; without it (a preview,
/// or a test that has not wired AI) the sheet just transcribes. [runner] is
/// what actually carries a command out; [speech] is optional read-aloud.
Future<VoiceSheetResult?> showAddThoughtSheet(
  BuildContext context, {
  required VoiceController voice,
  AiController? ai,
  VoiceCommandRunner? runner,
  SpeechService? speech,
  DateTime? day,
  String earlierToday = '',
  String earlierNotes = '',
  VoidCallback? onOpenVoiceSettings,
}) {
  return showModalBottomSheet<VoiceSheetResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (_) => _AddThoughtSheet(
      voice: voice,
      ai: ai,
      runner: runner,
      speech: speech,
      day: day ?? DateTime.now(),
      earlierToday: earlierToday,
      earlierNotes: earlierNotes,
      onOpenVoiceSettings: onOpenVoiceSettings,
    ),
  );
}

enum _Stage { ready, listening, review, confirm }

class _AddThoughtSheet extends StatefulWidget {
  const _AddThoughtSheet({
    required this.voice,
    required this.day,
    required this.earlierToday,
    required this.earlierNotes,
    this.ai,
    this.runner,
    this.speech,
    this.onOpenVoiceSettings,
  });

  final VoiceController voice;
  final DateTime day;

  /// Today's note so far, and a few earlier days, so a question can avoid
  /// asking what the diary already answers.
  final String earlierToday;
  final String earlierNotes;

  final AiController? ai;
  final VoiceCommandRunner? runner;
  final SpeechService? speech;
  final VoidCallback? onOpenVoiceSettings;

  @override
  State<_AddThoughtSheet> createState() => _AddThoughtSheetState();
}

class _AddThoughtSheetState extends State<_AddThoughtSheet>
    with WidgetsBindingObserver {
  final _transcript = TextEditingController();
  final _instruction = TextEditingController();
  final _transcriptFocus = FocusNode();

  _Stage _stage = _Stage.ready;
  LiveVoiceSession? _session;
  StreamSubscription<String>? _transcripts;
  StreamSubscription<double>? _levels;
  StreamSubscription<ChunkCut>? _cuts;
  double _level = 0;
  String? _error;
  String? _errorHint;

  /// The part of what has been heard that is settled, and the part still being
  /// spoken. Kept apart so the newest sentence can be painted in a lighter tone
  /// and then settle into full ink, which reads as typing rather than as the
  /// whole paragraph refreshing.
  String _settled = '';
  String _forming = '';

  /// True once the final transcript is being classified or reviewed, so a late
  /// stream event cannot overwrite the review box.
  bool _finalising = false;

  // --- Follow-up questions ---

  /// The question currently on screen, if any.
  String? _question;
  final Set<String> _asked = {};
  DateTime? _lastAskedAt;
  bool _asking = false;


  // --- Confirmation ---

  VoiceCommand? _pendingCommand;
  CommandOutcome? _pendingOutcome;

  bool get _canClassify =>
      widget.ai != null &&
      widget.runner != null &&
      widget.voice.voiceSettings.commandsEnabled;

  bool get _canAskQuestions =>
      widget.ai != null && widget.voice.voiceSettings.followUpsEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Readiness may have changed since settings was last opened. Deferred:
    // refresh notifies the app-wide controller, and doing that during this
    // first build would rebuild the scope mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.voice.refresh());
    });
  }

  /// Leaving the app ends the capture.
  ///
  /// A phone that is switched away from, or a window that is minimised, should
  /// not keep the microphone open: the person cannot see the transcript, the
  /// microphone light stays on, and whatever is picked up is not theirs any
  /// more. The words already heard are kept — this stops, it does not throw
  /// them away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_stage == _Stage.listening && _session != null) {
        unawaited(_stopRecording());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _transcripts?.cancel();
    _levels?.cancel();
    _cuts?.cancel();
    _session?.cancel();
    _transcript.dispose();
    _instruction.dispose();
    _transcriptFocus.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    setState(() {
      _error = null;
      _errorHint = null;
      _stage = _Stage.listening;
      _level = 0;
      _question = null;
      _asked.clear();
      _lastAskedAt = null;
      _finalising = false;
      _settled = '';
      _forming = '';
    });

    try {
      final session = await widget.voice.engine.startLive(
        pauseAfterSpeech: widget.voice.voiceSettings.pauseAfterSpeech,
      );
      _session = session;
      _transcripts = session.transcripts.listen(_onTranscript);
      _levels = session.levels.listen((value) {
        if (mounted) setState(() => _level = value);
      });
      // Where a pause ended a sentence tells the app whether this person's
      // pauses are being cut short, which is the only honest way to suggest a
      // better length.
      _cuts = session.cuts?.listen((cut) {
        unawaited(widget.voice.recordCut(cut));
      });
    } on VoiceException catch (error) {
      _failRecording(error.message, error.hint);
    } catch (error) {
      _failRecording('The microphone could not be started.', '$error');
    }
  }

  /// A new chunk of transcript arrived while the person is still talking.
  void _onTranscript(String text) {
    if (!mounted || _finalising) return;
    final session = _session;
    final settled = session?.settled ?? '';
    setState(() {
      _settled = settled;
      _forming = settled.isEmpty
          ? text.trim()
          : _dropPrefix(text.trim(), settled);
      // The editable copy is the whole thing, so a person who stops to fix a
      // word gets everything they said.
      _transcript.text = text;
      // Read the newest words, but do not fight the person for the cursor.
      _transcript.selection = TextSelection.collapsed(
        offset: _transcript.text.length,
      );
    });
    unawaited(_maybeAskQuestion(text));
  }

  /// [text] without [prefix], or [text] itself if it does not start with it.
  static String _dropPrefix(String text, String prefix) {
    if (!text.startsWith(prefix)) return text;
    return text.substring(prefix.length).trimLeft();
  }

  void _failRecording(String message, String? hint) {
    unawaited(_levels?.cancel());
    _levels = null;
    unawaited(_transcripts?.cancel());
    _transcripts = null;
    unawaited(_cuts?.cancel());
    _cuts = null;
    if (!mounted) return;
    setState(() {
      _stage = _Stage.ready;
      _level = 0;
      _error = message;
      _errorHint = hint;
    });
  }

  Future<void> _stopRecording() async {
    // Not awaited: the level stream is irrelevant once the recording stops, and
    // a stream that is slow to close must not hold up the transcript.
    unawaited(_levels?.cancel());
    _levels = null;
    _finalising = true;
    if (!mounted) return;
    setState(() {
      _level = 0;
      _question = null;
    });

    final session = _session;
    _session = null;
    unawaited(_transcripts?.cancel());
    _transcripts = null;
    unawaited(_cuts?.cancel());
    _cuts = null;

    try {
      final result = session == null
          ? TranscriptResult(text: _transcript.text)
          : await session.finish();
      if (!mounted) return;
      if (result.text.trim().isNotEmpty) _transcript.text = result.text;

      final text = _transcript.text.trim();
      if (text.isEmpty) {
        setState(() {
          _stage = _Stage.ready;
          _finalising = false;
          _error = 'Nothing was recognised in that recording.';
          _errorHint = 'Try again somewhere quieter, a little closer to the mic.';
        });
        return;
      }

      await _decideWhatToDo(text);
    } on VoiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _finalising = false;
        _error = error.message;
        _errorHint = error.hint;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _finalising = false;
        _error = 'That recording could not be transcribed.';
        _errorHint = '$error';
      });
    }
  }

  /// Reads the finished words: a request to the app, or an entry to write.
  Future<void> _decideWhatToDo(String text) async {
    final ai = widget.ai;
    if (_canClassify && ai != null) {
      final reply = await ai.classifyCommand(
        transcript: text,
        context: 'the note for this day',
      );
      if (!mounted) return;
      final command = parseVoiceCommand(reply, text);
      if (command is! AddNoteCommand && command is! NoCommand) {
        await _runCommand(command, text);
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _stage = _Stage.review;
      _finalising = false;
    });
    // A person who just spoke usually wants to fix a word or two; put the
    // cursor at the end so typing continues the sentence.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _transcriptFocus.requestFocus();
      _transcript.selection = TextSelection.collapsed(
        offset: _transcript.text.length,
      );
    });
  }

  Future<void> _runCommand(VoiceCommand command, String originalText) async {
    final runner = widget.runner;
    if (runner == null) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.review;
        _finalising = false;
      });
      return;
    }

    final outcome = await runner.run(command, day: widget.day);
    if (!mounted) return;

    if (outcome.needsConfirmation) {
      setState(() {
        _pendingCommand = command;
        _pendingOutcome = outcome;
        _stage = _Stage.confirm;
        _finalising = false;
      });
      await _speakIfEnabled(outcome.spoken.isEmpty ? outcome.message : outcome.spoken);
      return;
    }

    if (!outcome.done) {
      // "I could not work that out": fall back to treating the words as an
      // entry rather than losing them.
      setState(() {
        _stage = _Stage.review;
        _finalising = false;
      });
      return;
    }

    await _speakIfEnabled(outcome.spoken.isEmpty ? outcome.message : outcome.spoken);
    if (!mounted) return;
    Navigator.of(context).pop(CommandResult(outcome));
  }

  Future<void> _confirmPending() async {
    final command = _pendingCommand;
    final runner = widget.runner;
    if (command == null || runner == null) return;

    final outcome = await runner.run(command, day: widget.day, confirmed: true);
    if (!mounted) return;
    await _speakIfEnabled(outcome.spoken.isEmpty ? outcome.message : outcome.spoken);
    if (!mounted) return;
    Navigator.of(context).pop(CommandResult(outcome));
  }

  void _cancelPending() {
    setState(() {
      _pendingCommand = null;
      _pendingOutcome = null;
      _stage = _Stage.ready;
      _error = null;
      _errorHint = null;
    });
  }

  Future<void> _speakIfEnabled(String text) async {
    if (!widget.voice.voiceSettings.speakQuestions) return;
    final speech = widget.speech;
    if (speech == null) return;
    await speech.speak(text);
  }

  /// Asks the AI for one follow-up question, at most occasionally.
  ///
  /// The throttle matters: re-transcription produces a new chunk every few
  /// seconds, and asking on every one would hammer a local model and flood the
  /// screen. One question in flight at a time, and a gap between them.
  Future<void> _maybeAskQuestion(String transcript) async {
    if (!_canAskQuestions || _asking) return;
    if (transcript.split(RegExp(r'\s+')).length < 8) return;

    final now = DateTime.now();
    final last = _lastAskedAt;
    if (last != null && now.difference(last) < const Duration(seconds: 9)) {
      return;
    }

    _asking = true;
    _lastAskedAt = now;
    try {
      final question = await widget.ai!.followUpQuestion(
        transcript: transcript,
        earlierToday: widget.earlierToday,
        earlierNotes: widget.earlierNotes,
        alreadyAsked: _asked,
      );
      if (!mounted || _finalising || question == null) return;
      _asked.add(question);
      setState(() => _question = question);
      await _speakIfEnabled(question);
    } catch (error) {
      debugPrint('A follow-up question failed: $error');
    } finally {
      _asking = false;
    }
  }

  Future<void> _cancelRecording() async {
    // Not awaited, for the same reason as stopping: throwing the recording away
    // must not wait on a stream closing.
    unawaited(_levels?.cancel());
    _levels = null;
    unawaited(_transcripts?.cancel());
    _transcripts = null;
    unawaited(_cuts?.cancel());
    _cuts = null;
    final session = _session;
    _session = null;
    await session?.cancel();
    if (!mounted) return;
    setState(() {
      _stage = _Stage.ready;
      _level = 0;
      _question = null;
      _finalising = false;
    });
  }

  void _send() {
    final text = _transcript.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(
      ThoughtResult(
        CapturedThought(text: text, instruction: _instruction.text.trim()),
      ),
    );
  }

  /// Picks a different route for a model that is not downloaded yet.
  void _openVoiceSettings() {
    Navigator.of(context).pop();
    widget.onOpenVoiceSettings?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready = widget.voice.ready;
    final checking = widget.voice.checking;

    return Padding(
      // Lift above the keyboard when the transcript is being edited.
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.mic, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Speak a thought',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Your words stay on this device. The AI turns them into the note.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          if (!ready && !checking)
            _missingModel(scheme, theme)
          else
            ..._content(theme, scheme),
        ],
      ),
    );
  }

  Widget _missingModel(ColorScheme scheme, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'One-time voice setup',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Verbal Outlet transcribes speech locally, so it needs a small '
            'voice model. Download it once (about 140 MB), then it works '
            'offline forever.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _openVoiceSettings,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Set up voice'),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(ThemeData theme, ColorScheme scheme) {
    return switch (_stage) {
      _Stage.ready => _readyContent(theme, scheme),
      _Stage.listening => _listeningContent(theme, scheme),
      _Stage.review => _reviewContent(theme, scheme),
      _Stage.confirm => _confirmContent(theme, scheme),
    };
  }

  List<Widget> _readyContent(ThemeData theme, ColorScheme scheme) {
    return [
      Center(
        child: _MicButton(
          onPressed: _startRecording,
          icon: Icons.mic,
          color: scheme.primary,
          onColor: scheme.onPrimary,
          size: 88,
          label: 'Tap and start talking',
        ),
      ),
      const SizedBox(height: 10),
      if (_canClassify)
        Text(
          'You can also ask for things: "search for the trip", "open yesterday".',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      if (_error != null) ...[
        const SizedBox(height: 16),
        _errorBox(scheme, theme),
      ],
      if (_transcript.text.trim().isNotEmpty) ...[
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => setState(() => _stage = _Stage.review),
          icon: const Icon(Icons.edit_note, size: 18),
          label: const Text('Use what you said last time'),
        ),
      ],
    ];
  }

  List<Widget> _listeningContent(ThemeData theme, ColorScheme scheme) {
    final settled = _settled.trim();
    final forming = _forming.trim();
    final hasWords = settled.isNotEmpty || forming.isNotEmpty;

    return [
      // The growing words come first: they are the proof it is working.
      Container(
        constraints: const BoxConstraints(minHeight: 76, maxHeight: 190),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: SingleChildScrollView(
          reverse: true,
          child: hasWords
              ? Text.rich(
                  TextSpan(
                    children: [
                      // Closed sentences hold still; the one being spoken now is
                      // softer, so new words read as being added rather than the
                      // paragraph being redrawn.
                      TextSpan(
                        text: settled.isEmpty ? '' : '$settled ',
                        style: TextStyle(color: scheme.onSurface),
                      ),
                      TextSpan(
                        text: forming,
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.62),
                        ),
                      ),
                    ],
                  ),
                  key: const ValueKey('live-transcript'),
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
                )
              : Text(
                  'Listening…',
                  key: const ValueKey('live-transcript'),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
      if (_question != null) ...[
        const SizedBox(height: 12),
        _QuestionCard(
          question: _question!,
          onDismiss: () => setState(() => _question = null),
        ),
      ],
      const SizedBox(height: 14),
      ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
          value: _level,
          minHeight: 8,
          backgroundColor: scheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(scheme.primary),
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: Text(
              _question == null
                  ? 'Listening… tap stop when you are done.'
                  : 'Answer out loud, or tap stop when you are done.',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _cancelRecording,
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey('voice-stop-button'),
            onPressed: _stopRecording,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('Stop'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _reviewContent(ThemeData theme, ColorScheme scheme) {
    return [
      TextField(
        controller: _transcript,
        focusNode: _transcriptFocus,
        key: const ValueKey('transcript-field'),
        minLines: 3,
        maxLines: 7,
        keyboardType: TextInputType.multiline,
        style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'What was heard',
          hintText: 'Fix a word if it misheard you, then send it.',
          contentPadding: EdgeInsets.all(14),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _instruction,
        style: theme.textTheme.bodySmall,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Icon(
            Icons.tune,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 34,
            minHeight: 34,
          ),
          hintText: 'Ask the AI for something specific (optional)',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 10,
          ),
        ),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          TextButton.icon(
            onPressed: () => setState(() {
              _stage = _Stage.ready;
              _transcript.clear();
              _question = null;
            }),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Say it again'),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _transcript.text.trim().isEmpty ? null : _send,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('Write it up'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _confirmContent(ThemeData theme, ColorScheme scheme) {
    final outcome = _pendingOutcome;
    return [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.error.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 20, color: scheme.error),
                const SizedBox(width: 8),
                Text(
                  'Just checking',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              outcome?.message ?? 'Are you sure?',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onErrorContainer,
                height: 1.45,
              ),
            ),
            if (widget.voice.voiceSettings.speakQuestions)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Read aloud. Say or tap yes to go ahead.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onErrorContainer.withValues(alpha: 0.8),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          TextButton(
            onPressed: _cancelPending,
            child: const Text('No, leave it'),
          ),
          const Spacer(),
          FilledButton.icon(
            key: const ValueKey('confirm-command-button'),
            onPressed: _confirmPending,
            icon: const Icon(Icons.check, size: 18),
            label: Text(confirmLabelFor(_pendingCommand ?? const NoCommand())),
          ),
        ],
      ),
    ];
  }

  Widget _errorBox(ColorScheme scheme, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (_errorHint != null) ...[
            const SizedBox(height: 4),
            Text(
              _errorHint!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onErrorContainer.withValues(alpha: 0.8),
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A follow-up question from the AI, mid-thought.
///
/// Quiet rather than alarming: it is an offer, and dismissing it costs nothing.
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.question, required this.onDismiss});

  final String question;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      key: const ValueKey('follow-up-question'),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.help_outline, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  question,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Answer while you keep talking.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Skip the question',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

/// The big round record control.
///
/// Only used in the ready state: while listening, the growing words are the
/// feedback, and a pulsing button beside a live transcript is just noise.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.onPressed,
    required this.icon,
    required this.color,
    required this.onColor,
    required this.size,
    required this.label,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final Color color;
  final Color onColor;
  final double size;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            key: const ValueKey('voice-record-button'),
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: size * 0.44, color: onColor),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
