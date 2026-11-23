/// Reading notes back in, so an export is a backup and not just a copy.
///
/// The format is whatever [NoteExporter] writes: an envelope with a `notes`
/// list, each day carrying its sections. This file is deliberately tolerant —
/// it accepts the single-day export too, ISO or epoch timestamps, and files
/// whose sections have no `id` (older exports) — because the point of an import
/// is to rescue data, and refusing a file over a field name helps nobody.
///
/// Merging uses the same rule as sync: per section, the newer edit wins. So
/// importing the same file twice changes nothing the second time, and importing
/// an old export cannot overwrite newer writing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/day_note.dart';
import 'note_store.dart';

/// What an import changed, in terms a person can read back.
class ImportReport {
  const ImportReport({
    required this.fileName,
    required this.days,
    required this.added,
    required this.updated,
    required this.unchanged,
  });

  final String fileName;

  /// Distinct days the file mentioned.
  final int days;

  final int added;

  /// Sections that already existed but were older than the imported copy.
  final int updated;

  /// Sections that were already there and newer, so they were left alone.
  final int unchanged;

  bool get changedNothing => added == 0 && updated == 0;

  /// One sentence for a snack bar.
  String get summary {
    if (changedNothing) {
      return unchanged == 0
          ? 'Nothing in that file to import.'
          : 'Already up to date — nothing to change.';
    }
    final parts = <String>[
      if (added > 0) '$added ${added == 1 ? 'entry' : 'entries'} added',
      if (updated > 0) '$updated ${updated == 1 ? 'entry' : 'entries'} updated',
    ];
    return parts.join(', ');
  }
}

/// A file that could not be read as notes, with a message worth showing.
class ImportException implements Exception {
  const ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Merges an exported file back into the store.
class NoteImporter {
  const NoteImporter();

  static const Uuid _uuid = Uuid();

  /// Reads [file] and merges it. Throws [ImportException] for a file that is
  /// not a export or cannot be read.
  Future<ImportReport> importFile(File file, {NoteStore? store}) async {
    String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (error) {
      throw ImportException(
        'Could not read that file: ${error.osError?.message ?? error.message}',
      );
    }
    return importText(
      text,
      fileName: file.uri.pathSegments.last,
      store: store,
    );
  }

  /// Merges exported JSON held in [text].
  ///
  /// [fileName] is only used in the report.
  Future<ImportReport> importText(
    String text, {
    String fileName = 'notes',
    NoteStore? store,
  }) async {
    final notes = _parse(text);
    final target = store ?? NoteStore.instance;

    var added = 0;
    var updated = 0;
    var unchanged = 0;
    final days = <DateTime>{};

    for (final note in notes) {
      days.add(note.day);
      final existing = target.noteFor(note.day);
      final existingIds = {
        for (final section in existing?.sections ?? const <NoteSection>[])
          section.id,
      };

      for (final section in note.sections) {
        final wasThere = existingIds.contains(section.id);
        final applied = target.applyRemoteSection(note.day, section);
        if (!applied) {
          unchanged++;
        } else if (wasThere) {
          updated++;
        } else {
          added++;
        }
      }
    }

    // Writes are queued in order and land before any later write, so the report
    // can be returned without waiting on the disk. Awaiting would also make an
    // import hang wherever the store's queue was started in another zone.
    unawaited(target.flush());

    return ImportReport(
      fileName: fileName,
      days: days.length,
      added: added,
      updated: updated,
      unchanged: unchanged,
    );
  }

  /// Pulls the day list out of whichever envelope the file uses.
  List<DayNote> _parse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const ImportException(
        'That file is not JSON. Choose a .json file exported from Verbal Outlet.',
      );
    }

    final rawDays = switch (decoded) {
      {'notes': final List<dynamic> notes} => notes,
      final List<dynamic> notes => notes,
      {'sections': List<dynamic> _} => [decoded],
      _ => null,
    };

    if (rawDays == null) {
      throw const ImportException(
        'That file does not look like a Verbal Outlet export.',
      );
    }

    final parsed = <DayNote>[];
    for (final entry in rawDays) {
      if (entry is! Map) continue;
      final note = _parseDay(entry.cast<String, dynamic>());
      if (note != null) parsed.add(note);
    }

    if (parsed.isEmpty) {
      throw const ImportException('That file has no notes in it.');
    }
    return parsed;
  }

  DayNote? _parseDay(Map<String, dynamic> json) {
    final day = _parseDate(json['day']) ?? _parseDate(json['date']);
    if (day == null) return null;
    final dayOnly = DateTime(day.year, day.month, day.day);

    final rawSections = json['sections'];
    if (rawSections is! List) return null;

    final sections = <NoteSection>[];
    for (final raw in rawSections) {
      if (raw is! Map) continue;
      final section = _parseSection(raw.cast<String, dynamic>(), dayOnly);
      if (section != null) sections.add(section);
    }

    // A day with no readable sections tells us nothing; skip rather than
    // create an empty note just because its day was mentioned.
    if (sections.isEmpty) return null;

    sections.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return DayNote(day: dayOnly, sections: sections);
  }

  NoteSection? _parseSection(Map<String, dynamic> json, DateTime day) {
    final createdAt = _parseDate(json['createdAt']) ?? day;

    // Older exports carried no id. A deterministic one keeps a repeated import
    // of the same file idempotent instead of duplicating every section.
    final id = switch (json['id']) {
      final String value when value.isNotEmpty => value,
      _ => 'imported-${_uuid.v5(
        Namespace.url.value,
        '$day-${createdAt.toIso8601String()}',
      )}',
    };

    final text = json['text'];
    final body = json['body'];
    // An import with no body is either an old export or a raw entry. Marking
    // it ready means it shows its words and never sits held with no way out.
    final hasBody = body is String && body.trim().isNotEmpty;
    return NoteSection(
      id: id,
      createdAt: createdAt,
      text: text is String ? text : '',
      body: hasBody ? body : '',
      state: hasBody
          ? NoteSection.stateFromName(json['state'])
          : ComposeState.ready,
      instruction: json['instruction'] is String
          ? json['instruction'] as String
          : '',
      composeError: json['composeError'] is String
          ? json['composeError'] as String
          : null,
      updatedAt: _parseDate(json['updatedAt']),
      deleted: json['deleted'] == true,
      duration: _parseDuration(json['durationMs']),
    );
  }

  /// Accepts ISO strings (what the exporter writes) and epoch milliseconds
  /// (what the database uses internally), because both have shipped.
  ///
  /// Hand-edited files sometimes write `2026-5-6`; Dart's parser wants the
  /// padded form, so a loose day-month-year fallback is here for them.
  static DateTime? _parseDate(Object? value) => switch (value) {
    final String text => DateTime.tryParse(text)?.toLocal() ?? _looseDate(text),
    final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
    _ => null,
  };

  static DateTime? _looseDate(String text) {
    final parts = text.split('-');
    if (parts.length < 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  static Duration? _parseDuration(Object? value) =>
      value is num ? Duration(milliseconds: value.toInt()) : null;
}
