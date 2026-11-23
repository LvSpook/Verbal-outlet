import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_scope.dart';
import '../ai/compose_scope.dart';
import '../capture/app_request_scope.dart';
import '../data/note_export.dart';
import '../data/note_store.dart';
import '../models/day_note.dart';
import '../screens/ai_settings_screen.dart';
import '../screens/sync_screen.dart';
import '../search/note_search.dart';
import '../utils/date_format.dart';
import '../voice/speech_service.dart';
import '../voice/voice_command_runner.dart';
import '../voice/voice_scope.dart';
import 'ai/ai_panel.dart';
import 'ai/entry_view.dart';
import 'export_feedback.dart';
import 'highlighted_text.dart';
import 'voice/add_thought_sheet.dart';

/// The editor for a single day's note, as a pane rather than a full screen.
///
/// A day has exactly one note. Adding works in two ways:
///
/// - Type in the box at the bottom and press Add (or Ctrl+Enter) to append a
///   new timestamped section.
/// - Click an existing section to edit its text in place.
///
/// [embedded] trims the chrome: no back button, a shorter title row, because
/// the calendar beside it already provides context and navigation.
class NoteEditorPane extends StatefulWidget {
  const NoteEditorPane({
    super.key,
    required this.day,
    this.embedded = false,
    this.onClose,
    this.onChanged,
    this.searchRequest = 0,
    this.captureRequest = 0,
    this.focusSectionId,
    this.onOpenAiSettings,
    this.speech,
  });

  final DateTime day;

  /// When true, the pane is shown beside the calendar instead of on its own.
  final bool embedded;

  /// Called when the close button is pressed. Omit to hide the button.
  final VoidCallback? onClose;

  /// Called whenever the note content changes, so the calendar can refresh.
  final VoidCallback? onChanged;

  /// Bump this to ask the pane to open its search field.
  ///
  /// A counter rather than a callback so a parent can trigger search without
  /// holding a controller for a widget it does not own the lifetime of.
  final int searchRequest;

  /// Bump this to ask the pane to put the cursor in the composer.
  ///
  /// A counter for the same reason as [searchRequest]: the pane is rebuilt and
  /// rekeyed when the day changes, so a value the parent passes in survives
  /// that, where a one-shot callback would not.
  final int captureRequest;

  /// Opens this section straight into its inline editor on first build.
  ///
  /// Set when a result from the all-notes search is chosen: the pane has just
  /// been created for that day, so there is no "update" to react to.
  final String? focusSectionId;

  /// Opens the AI settings screen. Shown from the assistant panel.
  final VoidCallback? onOpenAiSettings;

  /// Overrides the speech service, so a test never talks to the platform.
  final SpeechService? speech;

  @override
  State<NoteEditorPane> createState() => NoteEditorPaneState();
}

/// Public so a parent (the home screen) can route a Ctrl+F press at the pane
/// from anywhere in the window, not only when focus happens to be inside it.
class NoteEditorPaneState extends State<NoteEditorPane> {
  final NoteStore _store = NoteStore.instance;
  final _newSectionController = TextEditingController();
  final _newSectionFocus = FocusNode();

  /// An optional request for the AI, e.g. "make this a checklist".
  final _instructionController = TextEditingController();

  /// The search engine. Swapping this for a cloud/semantic implementation is
  /// the only change needed to make search smarter.
  final NoteSearcher _searcher = const LexicalSearcher();

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// Whether the search field is showing.
  bool _searching = false;

  /// Whether the AI assistant panel is showing beside the note.
  bool _aiOpen = false;

  /// Which section is currently being edited inline, if any.
  String? _editingSectionId;
  late final TextEditingController _editingController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _searchController.addListener(_onQueryChanged);
    // A pane that is created *because* a capture arrived (today's note was not
    // open) never sees a didUpdateWidget, so honour a non-zero counter here.
    if (widget.captureRequest > 0) focusComposer();
    // Likewise a pane created *because* a search hit chose this day.
    final focusSection = widget.focusSectionId;
    if (focusSection != null) _focusSectionAfterBuild(focusSection);
  }

  /// Opens the named section in the inline editor once the note is on screen.
  ///
  /// Deferred because the section's widget does not exist until the list has
  /// been laid out, and the editor needs the section's text, which only exists
  /// once the store has been read for this day.
  void _focusSectionAfterBuild(String sectionId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final note = _store.noteFor(_day);
      if (note == null) return;
      NoteSection? section;
      for (final entry in note.sections) {
        if (entry.id == sectionId) {
          section = entry;
          break;
        }
      }
      if (section == null) return;
      _startEditing(section);
      // Let search close if it was somehow open, so the editor is visible.
      if (_searching) {
        _searchController.clear();
        setState(() => _searching = false);
      }
    });
  }

  @override
  void didUpdateWidget(NoteEditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A parent asked for search (e.g. a window-level Ctrl+F).
    if (widget.searchRequest != oldWidget.searchRequest) {
      openSearch();
    }
    // A quick capture (hotkey, shortcut, or the New thought button) wants the
    // cursor ready. Also handled on first build, below, because opening today's
    // note creates this pane rather than updating it.
    if (widget.captureRequest != oldWidget.captureRequest) {
      focusComposer();
    }
    // And a pane reused for a newly chosen hit is keyed by day, so this only
    // fires when the same day is already open and a different section is picked.
    if (widget.focusSectionId != null &&
        widget.focusSectionId != oldWidget.focusSectionId) {
      _focusSectionAfterBuild(widget.focusSectionId!);
    }
    // Switching to a different day must not carry an in-progress edit or a
    // search across. A rebuild follows immediately, so the fields can be reset
    // directly without another setState.
    if (!isSameDay(oldWidget.day, widget.day)) {
      _editingSectionId = null;
      _newSectionController.clear();
      _searchController.clear();
      _searching = false;
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _newSectionController.dispose();
    _newSectionFocus.dispose();
    _instructionController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _editingController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _onQueryChanged() {
    // Rebuild so results follow the query as it is typed.
    if (mounted) setState(() {});
  }

  void _openSearch() {
    setState(() => _searching = true);
    // Focus after the field exists, or the keyboard never appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// Opens search from outside the widget, e.g. a window-level shortcut.
  void openSearch() {
    if (_searching) {
      _searchFocus.requestFocus();
      return;
    }
    _openSearch();
  }

  /// Puts the cursor in the composer, closing search first if it is open.
  ///
  /// Called by the home screen when a quick capture arrives. Deferred to after
  /// the frame, because the pane is often built in the same frame as the
  /// request and a focus node that is not yet in the tree cannot take focus.
  void focusComposer() {
    if (_searching) {
      _searchController.clear();
      setState(() => _searching = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _newSectionFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchController.clear();
    setState(() => _searching = false);
  }

  /// Opens AI settings, unless a parent supplied its own route.
  void _openAiSettings() {
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const AiSettingsScreen()));
  }

  /// Opens the voice model setup, which lives in the settings screen.
  void _openVoiceSettings() {
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const SyncScreen()));
  }

  Widget _buildAiPanel(DayNote note) {
    return AiPanel(
      note: note,
      onClose: () => setState(() => _aiOpen = false),
      onOpenSettings: widget.onOpenAiSettings ?? _openAiSettings,
    );
  }

  void _clearQuery() {
    _searchController.clear();
    _searchFocus.requestFocus();
  }

  DateTime get _day => dateOnly(widget.day);

  void _addSection() {
    final text = _newSectionController.text.trim();
    if (text.isEmpty) return;

    final instruction = _instructionController.text.trim();
    final queue = ComposeScope.maybeOf(context);

    if (queue == null) {
      // No queue (a preview, or a test that has not wired AI): write plainly so
      // the app still works, just without the AI pass.
      _store.appendToDay(_day, text);
    } else {
      // Held, not written: the note shows a waiting line until the AI answers.
      // The queue is kicked rather than called per entry, so it can notice the
      // AI is down once and leave the entry waiting instead of failing it.
      _store.holdForCompose(_day, text, instruction: instruction);
      queue.kick();
    }

    _newSectionController.clear();
    _instructionController.clear();
    widget.onChanged?.call();

    // Keep the cursor in the box so several thoughts can be added in a row.
    _newSectionFocus.requestFocus();
  }

  /// Holds a spoken thought so the AI can write it up.
  ///
  /// Deliberately the same path as a typed one: the words are stored pending
  /// and the queue takes it from there, so a voice entry never appears as raw
  /// text and never fails differently from a typed entry.
  void _addSpokenThought(CapturedThought thought) {
    final text = thought.text.trim();
    if (text.isEmpty) return;

    final queue = ComposeScope.maybeOf(context);
    if (queue == null) {
      _store.appendToDay(_day, text);
    } else {
      _store.holdForCompose(
        _day,
        text,
        instruction: thought.instruction,
      );
      queue.kick();
    }
    widget.onChanged?.call();
  }

  /// Opens the voice sheet. Explains itself when voice is not set up.
  Future<void> _openVoiceSheet() async {
    final voice = VoiceScope.maybeOf(context);
    if (voice == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Voice is not available here.')),
        );
      return;
    }

    // Check the model before choosing what the sheet should show: opening
    // straight into "set up voice" when it is actually ready would be wrong.
    await voice.refresh();
    if (!mounted) return;

    final result = await showAddThoughtSheet(
      context,
      voice: voice,
      ai: AiScope.maybeOf(context),
      runner: _commandRunner(),
      speech: _speechService,
      day: _day,
      earlierToday: _earlierToday(),
      earlierNotes: _earlierNotes(),
      onOpenVoiceSettings: _openVoiceSettings,
    );
    if (result == null || !mounted) return;

    switch (result) {
      case ThoughtResult(:final thought):
        _addSpokenThought(thought);
      case CommandResult(:final outcome):
        // The command has already run; say what happened.
        _showOutcome(outcome.message);
    }
  }

  /// The command runner, built from the scopes this pane already has.
  ///
  /// A new one per call is cheap and keeps it out of the widget's fields, where
  /// it would hold a stale day.
  VoiceCommandRunner? _commandRunner() {
    final mailbox = AppRequestScope.maybeOf(context);
    if (mailbox == null) return null;
    return VoiceCommandRunner(
      store: _store,
      mailbox: mailbox,
      composeQueue: ComposeScope.maybeOf(context),
    );
  }

  /// Reads questions aloud if the person asked for that, and the platform can.
  SpeechService? get _speechService => widget.speech ?? SpeechService();

  /// Today's earlier entries, so a follow-up question does not ask what the
  /// diary already says.
  String _earlierToday() {
    final note = _store.noteFor(_day);
    if (note == null || note.isEmpty) return '';
    return note.visible.map((section) => section.content.trim()).join('\n');
  }

  /// A few recent days, trimmed so the prompt stays short.
  String _earlierNotes() {
    final recent = <DayNote>[];
    for (final note in _store.allNotes.reversed) {
      if (isSameDay(note.day, _day) || note.isEmpty) continue;
      recent.add(note);
      if (recent.length >= 3) break;
    }
    if (recent.isEmpty) return '';
    final text = recent
        .map(
          (note) =>
              '${formatDayTitle(note.day)}:\n'
              '${note.visible.map((s) => '- ${s.content.trim()}').join('\n')}',
        )
        .join('\n\n');
    return text.length > 1800 ? '${text.substring(0, 1800)}…' : text;
  }

  void _showOutcome(String message) {
    if (message.trim().isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _startEditing(NoteSection section) {
    setState(() {
      _editingSectionId = section.id;
      _editingController.text = section.text;
    });
  }

  void _commitEditing() {
    final id = _editingSectionId;
    if (id == null) return;

    _store.updateSection(_day, id, _editingController.text);
    widget.onChanged?.call();
    setState(() => _editingSectionId = null);

    // An edit clears the old AI version, so the entry is waiting again. Hand it
    // straight back to the queue so the note catches up without another tap.
    final note = _store.noteFor(_day);
    final section = note?.sections.where((entry) => entry.id == id).firstOrNull;
    final queue = ComposeScope.maybeOf(context);
    if (queue != null && section != null && section.isPending) {
      queue.compose(_day, section);
    }
  }

  void _cancelEditing() => setState(() => _editingSectionId = null);

  void _deleteSection(NoteSection section) {
    _store.removeSection(_day, section.id);
    widget.onChanged?.call();

    // The deletion is a tombstone, so it can be taken back. Someone tapping the
    // three-dot menu does not get the spoken confirmation the voice path has,
    // and a thought is not something to lose to a mis-tap.
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Entry deleted.'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              if (_store.restoreSection(_day, section.id)) {
                widget.onChanged?.call();
              }
            },
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final note = _store.noteOrEmpty(_day);
    final today = dateOnly(DateTime.now());
    final isToday = isSameDay(_day, today);
    final query = _searchController.text.trim();
    final result = _searching && query.isNotEmpty
        ? _searcher.search(note, query)
        : null;

    return Shortcuts(
      shortcuts: const {
        // Escape closes search when it is open. Ctrl+F is handled a level up,
        // by the window, so it works even when nothing in the pane has focus.
        SingleActivator(LogicalKeyboardKey.escape): _CloseSearchIntent(),
      },
      child: Actions(
        actions: {
          _CloseSearchIntent: CallbackAction<_CloseSearchIntent>(
            onInvoke: (_) {
              if (_searching) _closeSearch();
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Only room for the assistant beside the note on a wide pane; on a
            // narrow one it would squeeze the note into nothing.
            final canShowAiBeside = constraints.maxWidth >= 620;
            final aiBeside = _aiOpen && canShowAiBeside;

            final noteColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PaneHeader(
                  embedded: widget.embedded,
                  isToday: isToday,
                  day: _day,
                  note: note,
                  onClose: widget.onClose,
                  onSearch: _searching ? null : _openSearch,
                  searchAvailable: note.isNotEmpty,
                  onAi: () => setState(() => _aiOpen = !_aiOpen),
                  aiOpen: _aiOpen,
                ),
                if (_searching)
                  _SearchBar(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    engineName: _searcher.engineName,
                    matchCount: result?.hits.length,
                    hasQuery: query.isNotEmpty,
                    onClear: _clearQuery,
                    onClose: _closeSearch,
                  ),
                Expanded(
                  // The list scrolls under the buttons, which stay pinned so a
                  // thought can be spoken from anywhere in a long note.
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: result == null
                            ? _buildBody(context, note)
                            : _buildResults(context, result),
                      ),
                      if (!_searching)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: _FloatingCaptureButtons(
                            onVoice: _openVoiceSheet,
                            onText: () {
                              // Same as a quick capture: put the cursor in the
                              // docked composer, which stays the text path.
                              if (aiBeside) setState(() => _aiOpen = false);
                              focusComposer();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                if (!_searching && !aiBeside)
                  _Composer(
                    controller: _newSectionController,
                    focusNode: _newSectionFocus,
                    instructionController: _instructionController,
                    isFirst: note.isEmpty,
                    isToday: isToday,
                    onAdd: _addSection,
                    aiReady: ComposeScope.maybeOf(context)?.blockedReason == null,
                    busy: ComposeScope.maybeOf(context)?.busy ?? false,
                  ),
              ],
            );

            if (!aiBeside) {
              // Narrow pane: the assistant replaces the note rather than
              // sitting beside it.
              if (_aiOpen) return _buildAiPanel(note);
              return noteColumn;
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: noteColumn),
                SizedBox(
                  width: constraints.maxWidth >= 900 ? 380 : 320,
                  child: _buildAiPanel(note),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Search results, with the matching words highlighted.
  Widget _buildResults(BuildContext context, NoteSearchResult result) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (result.hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                'No matches on this day',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Try a different word, or a word you might have used instead.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.interpretation != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome, size: 15, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.interpretation!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            itemCount: result.hits.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final hit = result.hits[index];
              return _SearchHitCard(
                key: ValueKey('hit-${hit.section.id}'),
                hit: hit,
                query: result.query,
                onOpen: () {
                  // Jump into the section itself, ready to edit.
                  _startEditing(hit.section);
                  _closeSearch();
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, DayNote note) {
    final theme = Theme.of(context);

    // A day can have nothing to show yet and still have work in flight, so the
    // empty state is only for a genuinely untouched day.
    if (note.sections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.water_drop_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'Nothing here yet',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Add the first thought for this day below. It becomes a note '
                'once the AI has written it up.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      // Extra bottom room so the last entry is not hidden behind the pinned
      // capture buttons.
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
      itemCount: note.sections.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final section = note.sections[index];
        return _SectionCard(
          section: section,
          isEditing: _editingSectionId == section.id,
          editingController: _editingController,
          onStartEditing: () => _startEditing(section),
          onCommit: _commitEditing,
          onCancel: _cancelEditing,
          onDelete: () => _deleteSection(section),
          onRetry: section.state == ComposeState.failed
              ? () => _retryCompose(section)
              : null,
        );
      },
    );
  }

  /// Asks the queue to try one failed entry again.
  void _retryCompose(NoteSection section) {
    final queue = ComposeScope.maybeOf(context);
    if (queue == null) return;
    queue.retry(_day, section);
  }
}

/// Title row at the top of the note pane.
class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.embedded,
    required this.isToday,
    required this.day,
    required this.note,
    required this.onClose,
    this.onSearch,
    this.searchAvailable = false,
    this.onAi,
    this.aiOpen = false,
  });

  final bool embedded;
  final bool isToday;
  final DateTime day;

  /// The day's note, for exporting it from the overflow menu.
  final DayNote note;

  final VoidCallback? onClose;

  /// Opens the search field. Null while search is already open.
  final VoidCallback? onSearch;

  /// Whether there is anything to search yet.
  final bool searchAvailable;

  /// Toggles the assistant panel. Null hides the button (e.g. in tests that
  /// don't wire AI).
  final VoidCallback? onAi;

  /// Whether the assistant is currently open, for the button state.
  final bool aiOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: EdgeInsets.fromLTRB(
        embedded ? 24 : 20,
        embedded ? 20 : 12,
        12,
        12,
      ),
      decoration: BoxDecoration(
        border: embedded
            ? null
            : Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        isToday ? 'Today' : formatDayTitle(day),
                        overflow: TextOverflow.ellipsis,
                        style:
                            (embedded
                                    ? theme.textTheme.headlineSmall
                                    : theme.textTheme.titleLarge)
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.4,
                                ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  formatDaySubtitle(day) +
                      (note.sectionCount == 0
                          ? ''
                          : note.sectionCount == 1
                          ? '  ·  1 addition'
                          : '  ·  ${note.sectionCount} additions'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (onAi != null)
            IconButton(
              tooltip: aiOpen ? 'Hide assistant' : 'Ask the assistant',
              onPressed: onAi,
              icon: Icon(
                aiOpen ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                size: 20,
                color: aiOpen ? scheme.primary : null,
              ),
            ),
          if (onSearch != null)
            IconButton(
              tooltip: 'Search this note',
              onPressed: searchAvailable ? onSearch : null,
              icon: const Icon(Icons.search, size: 20),
            ),
          _NoteMenu(note: note),
          if (onClose != null)
            IconButton(
              tooltip: 'Close note',
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20),
            ),
        ],
      ),
    );
  }
}

/// The note's overflow menu: actions that apply to the whole day.
///
/// Kept as its own widget so it can own the "export in progress" state without
/// rebuilding the header on every tap. The copy action is here too, since a
/// three-dot menu is where people look for it.
class _NoteMenu extends StatefulWidget {
  const _NoteMenu({required this.note});

  final DayNote note;

  @override
  State<_NoteMenu> createState() => _NoteMenuState();
}

class _NoteMenuState extends State<_NoteMenu> {
  final NoteExporter _exporter = NoteExporter();
  bool _busy = false;

  Future<void> _export(ExportFormat format) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await _exporter.exportDay(widget.note, format: format);
      if (mounted) showExportResult(context, file);
    } catch (error) {
      if (mounted) showExportError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final text = widget.note.visible
        .map((section) => section.content)
        .join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Note copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final empty = widget.note.isEmpty;

    return PopupMenuButton<String>(
      tooltip: 'Note options',
      enabled: !_busy,
      icon: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.more_vert, size: 20, color: scheme.onSurfaceVariant),
      onSelected: (value) {
        switch (value) {
          case 'copy':
            _copy();
          case 'markdown':
            _export(ExportFormat.markdown);
          case 'json':
            _export(ExportFormat.json);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'copy',
          enabled: !empty,
          child: const _MenuItem(
            icon: Icons.copy_all_outlined,
            label: 'Copy note',
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'markdown',
          enabled: !empty,
          child: const _MenuItem(
            icon: Icons.description_outlined,
            label: 'Export as Markdown',
          ),
        ),
        PopupMenuItem(
          value: 'json',
          enabled: !empty,
          child: const _MenuItem(
            icon: Icons.data_object,
            label: 'Export as JSON',
          ),
        ),
      ],
    );
  }
}

/// An icon and label inside a popup menu item.
class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        // Flexible, because a popup is only as wide as its widest item and a
        // narrow window can otherwise overflow the label.
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

/// One timestamped part of the day's note.
class _SectionCard extends StatefulWidget {
  const _SectionCard({
    required this.section,
    required this.isEditing,
    required this.editingController,
    required this.onStartEditing,
    required this.onCommit,
    required this.onCancel,
    required this.onDelete,
    this.onRetry,
  });

  final NoteSection section;
  final bool isEditing;
  final TextEditingController editingController;
  final VoidCallback onStartEditing;
  final VoidCallback onCommit;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  /// Tries a failed entry through the AI again.
  final VoidCallback? onRetry;

  @override
  State<_SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<_SectionCard> {
  /// Whether the person's original words are showing under the AI version.
  bool _showOriginal = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final section = widget.section;
    final waiting = section.isPending;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: widget.isEditing ? scheme.surfaceContainerHigh : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        formatClock(section.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (section.duration != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          formatDuration(section.duration!),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (widget.isEditing)
                    _InlineEditor(
                      controller: widget.editingController,
                      onCommit: widget.onCommit,
                      onCancel: widget.onCancel,
                    )
                  else if (waiting)
                    _HeldEntry(
                      section: section,
                      onRetry: widget.onRetry,
                      onShowOriginal: () =>
                          setState(() => _showOriginal = !_showOriginal),
                      showOriginal: _showOriginal,
                    )
                  else
                    InkWell(
                      onTap: widget.onStartEditing,
                      borderRadius: BorderRadius.circular(10),
                      hoverColor: scheme.primaryContainer.withValues(
                        alpha: 0.22,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            EntryView(source: section.content),
                            if (section.body.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: _OriginalToggle(
                                  open: _showOriginal,
                                  onTap: () => setState(
                                    () => _showOriginal = !_showOriginal,
                                  ),
                                  text: section.text,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!widget.isEditing)
              PopupMenuButton<String>(
                tooltip: 'Section options',
                icon: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      widget.onStartEditing();
                    case 'delete':
                      widget.onDelete();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// A section waiting for the AI: a quiet line, the words it is holding, and a
/// way to retry. Nothing here pretends to be note content.
class _HeldEntry extends StatelessWidget {
  const _HeldEntry({
    required this.section,
    required this.onRetry,
    required this.onShowOriginal,
    required this.showOriginal,
  });

  final NoteSection section;
  final VoidCallback? onRetry;
  final VoidCallback onShowOriginal;
  final bool showOriginal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = section.state == ComposeState.failed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed
                    ? Icons.error_outline
                    : Icons.hourglass_top_rounded,
                size: 16,
                color: failed ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  failed
                      ? 'The AI could not write this one yet.'
                      : 'Waiting for the AI to write this up…',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: failed ? scheme.error : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (failed && onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
          if (failed && section.composeError != null) ...[
            const SizedBox(height: 4),
            Text(
              section.composeError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 8),
          _OriginalToggle(
            open: showOriginal,
            onTap: onShowOriginal,
            text: section.text,
            label: 'Your words (kept safe)',
          ),
        ],
      ),
    );
  }
}

/// "Your words" — a small link that reveals the original text beneath.
class _OriginalToggle extends StatelessWidget {
  const _OriginalToggle({
    required this.open,
    required this.onTap,
    required this.text,
    this.label = 'Your words',
  });

  final bool open;
  final VoidCallback onTap;
  final String text;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 2, 0, 2),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: scheme.outlineVariant,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _InlineEditor extends StatelessWidget {
  const _InlineEditor({
    required this.controller,
    required this.onCommit,
    required this.onCancel,
  });

  final TextEditingController controller;
  final VoidCallback onCommit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyS, control: true):
                _CommitIntent(),
            SingleActivator(LogicalKeyboardKey.escape): _CancelIntent(),
          },
          child: Actions(
            actions: {
              _CommitIntent: CallbackAction<_CommitIntent>(
                onInvoke: (_) {
                  onCommit();
                  return null;
                },
              ),
              _CancelIntent: CallbackAction<_CancelIntent>(
                onInvoke: (_) {
                  onCancel();
                  return null;
                },
              ),
            },
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.all(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
            const SizedBox(width: 4),
            FilledButton(onPressed: onCommit, child: const Text('Save')),
          ],
        ),
      ],
    );
  }
}

/// A stable handle on the composer box, so a test can find it without relying
/// on TextField order (the optional instruction field follows it).
const Key composerFieldKey = Key('composer-field');

/// The always-visible box at the bottom for adding a new section.
///
/// Everything typed here is a *thought*, not a finished entry: pressing Write
/// hands it to the AI, which turns it into the note. The optional instruction
/// field is the person's chance to steer that — "checklist", "one line",
/// "chart the costs" — and is empty most of the time.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.instructionController,
    required this.isFirst,
    required this.isToday,
    required this.onAdd,
    this.aiReady = true,
    this.busy = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextEditingController instructionController;
  final bool isFirst;
  final bool isToday;
  final VoidCallback onAdd;

  /// False when the AI looks unavailable, so the button can say what will
  /// happen instead of promising a note that cannot arrive.
  final bool aiReady;

  /// True while the queue is writing, so a second press does not look ignored.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  onAdd,
            },
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              key: composerFieldKey,
              minLines: 2,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: isFirst
                    ? (isToday
                          ? 'What happened today?'
                          : 'Write the first note for this day…')
                    : 'Add another thought to this day…',
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: instructionController,
            textInputAction: TextInputAction.done,
            style: theme.textTheme.bodySmall,
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
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  aiReady
                      ? 'Ctrl+Enter to write it up'
                      : 'AI offline — saved until it is back',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: aiReady
                        ? scheme.onSurfaceVariant
                        : scheme.error.withValues(alpha: 0.85),
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: onAdd,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(busy ? 'Writing…' : 'Write it up'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The pinned pair of capture buttons over the note.
///
/// Voice is the larger, primary control: this is a voice diary, and speaking
/// should be the easiest thing to reach. The text button sits under it for
/// when typing is easier. Both sit above the list, so scrolling a long note
/// never hides them.
class _FloatingCaptureButtons extends StatelessWidget {
  const _FloatingCaptureButtons({required this.onVoice, required this.onText});

  final VoidCallback onVoice;
  final VoidCallback onText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.small(
          heroTag: 'capture-text',
          tooltip: 'Write a thought',
          onPressed: onText,
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          child: const Icon(Icons.keyboard_outlined, size: 20),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'capture-voice',
          tooltip: 'Speak a thought',
          onPressed: onVoice,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          child: const Icon(Icons.mic, size: 26),
        ),
      ],
    );
  }
}

/// The search field that appears under the header.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.engineName,
    required this.matchCount,
    required this.hasQuery,
    required this.onClear,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String engineName;
  final int? matchCount;
  final bool hasQuery;
  final VoidCallback onClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final String helper;
    if (!hasQuery) {
      helper = '$engineName search · understands related words and typos';
    } else if (matchCount == null || matchCount == 0) {
      helper = 'No matches on this day';
    } else if (matchCount == 1) {
      helper = '1 match';
    } else {
      helper = '$matchCount matches, best first';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  textInputAction: TextInputAction.search,
                  style: theme.textTheme.bodyLarge,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search this day — e.g. tired, money, walk',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: hasQuery
                        ? IconButton(
                            tooltip: 'Clear search',
                            onPressed: onClear,
                            icon: const Icon(
                              Icons.backspace_outlined,
                              size: 18,
                            ),
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Close search',
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              helper,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One matching section, with the hit words picked out.
class _SearchHitCard extends StatelessWidget {
  const _SearchHitCard({
    super.key,
    required this.hit,
    required this.query,
    required this.onOpen,
  });

  final NoteHit hit;
  final String query;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final excerpt = hit.excerpt;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    formatClock(hit.section.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.north_east,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _HighlightedText(
                text: excerpt,
                spans: hit.spans,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              ),
              if (hit.reasons.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome, size: 13, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        hit.reasons.first,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws text with some character ranges emphasised.
///
/// The spans are already offsets into this exact string — the search engine
/// builds them that way — so highlighting cannot land on the wrong letters.
class _HighlightedText extends StatelessWidget {
  const _HighlightedText({required this.text, required this.spans, this.style});

  final String text;
  final List<MatchSpan> spans;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => HighlightedText(
    text: text,
    spans: spans,
    style: style,
  );
}

class _CommitIntent extends Intent {
  const _CommitIntent();
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}

class _CloseSearchIntent extends Intent {
  const _CloseSearchIntent();
}


