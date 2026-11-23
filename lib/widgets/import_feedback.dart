/// What the user sees after an import.
///
/// Import is a scary word for "overwrite my notes", so the message is specific:
/// how many entries were added and updated, or that nothing needed changing.
/// The file is never touched, so a mistaken import is undone by exporting or
/// syncing, not by a warning dialog before the fact.
library;

import 'package:material_ui/material_ui.dart';

import '../data/note_import.dart';

/// Reports what an import changed.
void showImportResult(BuildContext context, ImportReport report) {
  final scheme = Theme.of(context).colorScheme;

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          report.summary,
          // The summary is a sentence, not an error; colour it by outcome so
          // "nothing to change" does not look like a failure.
          style: TextStyle(
            color: report.changedNothing
                ? scheme.onSurfaceVariant
                : scheme.onSurface,
          ),
        ),
      ),
    );
}

/// Reports a file that could not be read, without claiming anything changed.
void showImportError(BuildContext context, Object error) {
  final scheme = Theme.of(context).colorScheme;
  final message = error is ImportException ? error.message : '$error';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: scheme.errorContainer,
        content: Text(
          message,
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
}
