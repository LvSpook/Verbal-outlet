import 'package:material_ui/material_ui.dart';

import '../data/note_store.dart';
import '../widgets/global_search_dialog.dart';
import '../widgets/note_editor_pane.dart';

/// Full-screen note page, used on narrow windows where a split view will not
/// fit. On desktop the same editor is shown as a pane beside the calendar.
class NotePage extends StatelessWidget {
  const NotePage({
    super.key,
    required this.day,
    this.focusComposer = false,
    this.focusSectionId,
  });

  final DateTime day;

  /// Opens with the cursor in the composer.
  ///
  /// Set by quick capture: on a phone the shortcut opens this page rather than
  /// a pane, and having to tap the text box after asking to write would undo
  /// the point of the shortcut.
  final bool focusComposer;

  /// Opens this section straight into its inline editor.
  ///
  /// Set when a result from the all-notes search is chosen on a phone, where
  /// there is no pane to open beside the calendar.
  final String? focusSectionId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to calendar',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const SizedBox.shrink(),
        actions: [
          IconButton(
            tooltip: 'Search all notes',
            onPressed: () => _searchAll(context),
            icon: const Icon(Icons.search),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: NoteEditorPane(
              // Keyed by the section being opened, so choosing a second result
              // on the same day rebuilds the pane and focuses the new section
              // instead of leaving the old editor state in place.
              key: ValueKey('${dateOnly(day)}-$focusSectionId'),
              day: dateOnly(day),
              captureRequest: focusComposer ? 1 : 0,
              focusSectionId: focusSectionId,
            ),
          ),
        ),
      ),
    );
  }

  /// Searches every note from inside a note, then shows the chosen day.
  ///
  /// Replaces this page rather than stacking a second one, so Back still
  /// returns to the calendar rather than walking through every search.
  Future<void> _searchAll(BuildContext context) async {
    final navigator = Navigator.of(context);
    final chosen = await showGlobalSearch(context, store: NoteStore.instance);
    if (chosen == null || !context.mounted) return;

    await navigator.pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (_) => NotePage(
          day: dateOnly(chosen.day),
          focusSectionId: chosen.hit.section.id,
        ),
      ),
    );
  }
}
