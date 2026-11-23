/// The one bit of UI both export buttons share.
///
/// After a file is written it is more useful to say *where* it went and offer to
/// open the folder than to show a spinner and a check mark: the user's next
/// question is always "where is it?".
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../data/note_export.dart';

/// Shows the written file in a snack bar, with a button that opens its folder.
///
/// Kept as a function rather than a widget so callers can use it from a menu
/// callback without holding state. The snack bar outlives the note pane, so the
/// action captures only the path.
void showExportResult(BuildContext context, File file) {
  final messenger = ScaffoldMessenger.of(context);
  final fileName = file.uri.pathSegments.last;

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Saved $fileName'),
            const SizedBox(height: 2),
            Text(
              file.parent.path,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Show folder',
          onPressed: () => revealFile(file),
        ),
      ),
    );
}

/// Reports a failed export without pretending it worked.
void showExportError(BuildContext context, Object error) {
  final message = error is ExportException ? error.message : '$error';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
        content: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
}
