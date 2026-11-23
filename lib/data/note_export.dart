/// Turning notes into files you can keep, print, or read elsewhere.
///
/// Two formats, because they answer different questions:
///
/// * **Markdown** is for a person: readable in any text editor, and it keeps the
///   timestamps so a day reads like a diary. This is the default.
/// * **JSON** is for a tool: the same shape the app uses and syncs, so nothing
///   is lost and it can be imported later.
///
/// Exporting writes into the Downloads folder rather than asking for a path, so
/// it is one action rather than a file dialog. The caller is told where the file
/// landed and can show or open it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/day_note.dart';
import '../utils/date_format.dart';

/// Which file to produce.
enum ExportFormat {
  markdown('Markdown', 'md'),
  json('JSON', 'json');

  const ExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

/// Writes notes to disk. Separate from the UI so it can be tested without one.
class NoteExporter {
  NoteExporter({Directory? directory}) : _override = directory;

  /// A directory supplied by a test; production uses Downloads.
  final Directory? _override;

  /// Where exports go: Downloads, falling back to Documents, then to the app's
  /// own folder on a platform with neither.
  Future<Directory> _directory() async {
    if (_override != null) {
      await _override.create(recursive: true);
      return _override;
    }

    final candidates = <Future<Directory?> Function()>[
      getDownloadsDirectory,
      getApplicationDocumentsDirectory,
      getApplicationSupportDirectory,
    ];
    for (final candidate in candidates) {
      try {
        final directory = await candidate();
        if (directory != null) {
          await directory.create(recursive: true);
          return directory;
        }
      } catch (_) {
        // Try the next one; a platform without Downloads should still export.
      }
    }
    // Last resort: the current directory, which is writable for a desktop app.
    return Directory.current;
  }

  /// Exports one day's note.
  ///
  /// Throws [ExportException] with a message meant for the user if there is
  /// nothing to write or the file cannot be saved.
  Future<File> exportDay(
    DayNote note, {
    ExportFormat format = ExportFormat.markdown,
  }) async {
    if (note.isEmpty) {
      throw const ExportException('This day has no note to export.');
    }

    final stamp = _dateKey(note.day);
    return _write(
      'Verbal Outlet - ${formatDayShort(note.day)}.$stamp.${format.extension}',
      format == ExportFormat.markdown
          ? renderDayMarkdown(note)
          : const JsonEncoder.withIndent('  ').convert({
              'app': 'verbal-outlet',
              'exportedAt': DateTime.now().toIso8601String(),
              'notes': [_dayJson(note)],
            }),
    );
  }

  /// Exports every day with a note, oldest first.
  Future<File> exportAll(
    Iterable<DayNote> notes, {
    ExportFormat format = ExportFormat.markdown,
  }) async {
    final days = notes.where((note) => note.isNotEmpty).toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    if (days.isEmpty) {
      throw const ExportException('There are no notes to export yet.');
    }

    final stamp = _dateKey(DateTime.now());
    return _write(
      'Verbal Outlet - all notes.$stamp.${format.extension}',
      format == ExportFormat.markdown
          ? renderAllMarkdown(days)
          : const JsonEncoder.withIndent('  ').convert({
              'app': 'verbal-outlet',
              'exportedAt': DateTime.now().toIso8601String(),
              'notes': [for (final note in days) _dayJson(note)],
            }),
    );
  }

  Future<File> _write(String name, String contents) async {
    try {
      final directory = await _directory();
      final file = File(p.join(directory.path, name));
      await file.writeAsString(contents, flush: true);
      return file;
    } on FileSystemException catch (error) {
      throw ExportException(
        'Could not save the file: ${error.osError?.message ?? error.message}',
      );
    }
  }

  static String _dateKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static Map<String, Object?> _dayJson(DayNote note) => {
    'day': _dateKey(note.day),
    'sections': [
      for (final section in note.sections)
        {
          'id': section.id,
          'createdAt': section.createdAt.toIso8601String(),
          // Carried so a re-import can tell a newer edit from an older one,
          // using the same rule as sync.
          'updatedAt': section.modifiedAt.toIso8601String(),
          // The original words, kept forever.
          'text': section.text,
          // What the AI wrote from them. Empty for older exports.
          'body': section.body,
          'state': section.state.name,
          if (section.instruction.isNotEmpty)
            'instruction': section.instruction,
          if (section.composeError != null)
            'composeError': section.composeError,
          'deleted': section.deleted,
        },
    ],
  };
}

/// Something to show the user, rather than a raw filesystem error.
class ExportException implements Exception {
  const ExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One day, as a readable Markdown document.
///
/// The heading is the full date, and each addition is a block quote after its
/// own timestamp, so the shape of the diary survives into the file.
String renderDayMarkdown(DayNote note) {
  final buffer = StringBuffer()
    ..writeln('# ${_longDate(note.day)}')
    ..writeln();

  final sections = note.visible;
  for (var i = 0; i < sections.length; i++) {
    final section = sections[i];
    buffer
      ..writeln('**${formatClock(section.createdAt)}**')
      ..writeln();
    // The AI version is what the note shows, so it is what the document leads
    // with. The original words follow, folded small, so nothing is lost.
    for (final line in section.content.split('\n')) {
      buffer.writeln(line.isEmpty ? '' : line);
    }
    if (section.body.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('<sub>Your words</sub>')
        ..writeln();
      for (final line in section.text.split('\n')) {
        buffer.writeln('> $line');
      }
    }
    if (i != sections.length - 1) buffer.writeln();
  }

  return '${buffer.toString().trimRight()}\n';
}

/// Every note, as one Markdown document with a title page line.
String renderAllMarkdown(List<DayNote> notes) {
  // Sorted here as well as in [NoteExporter.exportAll], so a direct call also
  // produces a diary in order.
  final ordered = [...notes]..sort((a, b) => a.day.compareTo(b.day));
  final buffer = StringBuffer()
    ..writeln('# Verbal Outlet')
    ..writeln()
    ..writeln(
      '${ordered.length} ${ordered.length == 1 ? 'entry' : 'entries'}, '
      'exported ${_longDate(DateTime.now())}.',
    );

  for (final note in ordered) {
    buffer
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..write(renderDayMarkdown(note));
  }

  return buffer.toString();
}

/// "Thursday 12 November 2026", spelled out for a document heading.
String _longDate(DateTime day) =>
    '${weekdayNames[day.weekday - 1]} '
    '${day.day} ${monthNames[day.month - 1]} ${day.year}';

/// Opens the folder containing [file] in the platform's file manager.
///
/// Best effort: on a platform where this is unavailable the user still has the
/// path, which the caller shows.
Future<bool> revealFile(File file) async {
  try {
    if (Platform.isWindows) {
      // `/select,` opens Explorer with the file highlighted.
      await Process.start('explorer.exe', ['/select,${file.path}']);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start('open', ['-R', file.path]);
      return true;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [p.dirname(file.path)]);
      return true;
    }
  } catch (_) {
    // No file manager, or the process could not start.
  }
  return false;
}
